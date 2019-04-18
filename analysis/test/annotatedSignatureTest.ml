(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Ast
open Analysis
open Statement
open Pyre

open Test
open AnnotatedTest

module Resolution = Analysis.Resolution

module Signature = Annotated.Signature

open Signature


let resolution =
  populate
    {|
      _T = typing.TypeVar('_T')
      _S = typing.TypeVar('_S')
      _R = typing.TypeVar('_R', int, float)
      _T_float_or_str = typing.TypeVar('_U', float, str)
      _T_float_str_or_union = (
        typing.TypeVar('_T_float_str_or_union', float, str, typing.Union[float, str])
      )
      _T_bound_by_float_str_union = (
        typing.TypeVar('_T_bound_by_float_str_union', bound=typing.Union[float, str])
      )

      class C(): ...
      class B(C): ...

      meta: typing.Type[typing.List[int]] = ...
      union: typing.Union[int, str] = ...
      int_to_int_dictionary: typing.Dict[int, int] = ...

      unknown: $unknown = ...
      g: typing.Callable[[int], bool]
      f: typing.Callable[[int], typing.List[bool]]

      class ESCAPED(typing.Generic[_T]): ...
    |}
  |> fun environment -> TypeCheck.resolution environment ()


let parse_annotation annotation =
  (* Allow untracked to create callables with unknowns, which would otherwise
     be generated from Callable.create on defines. *)
  annotation
  |> parse_single_expression
  |> Resolution.parse_annotation ~allow_untracked:true resolution


let test_select _ =
  let assert_select ?(allow_undefined = false) ?name callable arguments expected =
    let parse_callable callable =
      callable
      |> String.substr_replace_all ~pattern:"$literal_one" ~with_:"typing_extensions.Literal[1]"
      |> String.substr_replace_all
        ~pattern:"$literal_string"
        ~with_:"typing_extensions.Literal[\"string\"]"
      |> Format.asprintf "typing.Callable%s"
      |> parse_annotation
      |> Type.instantiate ~constraints:begin
        function
        | Type.Parametric { name = "ESCAPED"; parameters = [variable] } ->
            Type.Variable.Namespace.reset ();
            Some (Type.Variable.mark_all_free_variables_as_escaped variable)
        | _ ->
            None
      end
      |> function
      | Type.Callable ({ Type.Callable.implementation; overloads; _ } as callable) ->
          let undefined { Type.Callable.parameters; _ } =
            match parameters with
            | Type.Callable.Undefined -> true
            | _ -> false
          in
          if List.exists (implementation :: overloads) ~f:undefined && not allow_undefined then
            failwith "Undefined parameters"
          else
            name
            >>| Reference.create
            >>| (fun name -> { callable with kind = Named name })
            |> Option.value ~default:callable
      | _ ->
          failwith "Could not extract signatures"
    in
    let callable = parse_callable callable in
    Type.Variable.Namespace.reset ();
    let signature =
      let arguments =
        match parse_single_access ~convert:true (Format.asprintf "call%s" arguments) with
        | [Access.Identifier _; Access.Call { Node.value = arguments; _ }] -> arguments
        | _ -> failwith "Could not parse call"
      in
      Signature.select ~arguments ~resolution ~callable
    in
    let callable = { callable with Type.Callable.overloads = [] } in
    let expected =
      match expected with
      | `Found expected ->
          Found (parse_callable expected)
      | `NotFoundNoReason ->
          NotFound { callable; reason = None }
      | `NotFoundInvalidKeywordArgument (expression, annotation) ->
          let reason =
            { expression; annotation }
            |> Node.create_with_default_location
            |> fun invalid_argument -> Some (InvalidKeywordArgument invalid_argument)
          in
          NotFound { callable; reason }
      | `NotFoundInvalidVariableArgument (expression, annotation) ->
          let reason =
            { expression; annotation }
            |> Node.create_with_default_location
            |> fun invalid_argument -> Some (InvalidVariableArgument invalid_argument)
          in
          NotFound { callable; reason }
      | `NotFoundMissingArgument name ->
          NotFound { callable; reason = Some (MissingArgument name) }
      | `NotFoundMissingArgumentWithClosest (closest, name) ->
          NotFound {
            callable = parse_callable closest;
            reason = Some (MissingArgument name);
          }
      | `NotFoundTooManyArguments (expected, provided) ->
          NotFound {
            callable;
            reason = Some (TooManyArguments { expected; provided });
          }
      | `NotFoundTooManyArgumentsWithClosest (closest, expected, provided) ->
          NotFound {
            callable = parse_callable closest;
            reason = Some (TooManyArguments { expected; provided });
          }
      | `NotFoundUnexpectedKeyword name ->
          NotFound { callable; reason = Some (UnexpectedKeyword name) }
      | `NotFoundUnexpectedKeywordWithClosest (closest, name) ->
          NotFound {
            callable = parse_callable closest;
            reason = Some (UnexpectedKeyword name);
          }
      | `NotFoundMismatch (actual, actual_expression, expected, name, position) ->
          let actual_expression = parse_single_expression ~convert:true actual_expression in
          let reason =
            { actual; actual_expression; expected; name; position }
            |> Node.create_with_default_location
            |> fun mismatch -> Some (Mismatch mismatch)
          in
          NotFound { callable; reason }
      | `NotFoundMismatchWithClosest (closest, actual, actual_expression, expected, name, position)
        ->
          let actual_expression = parse_single_expression ~convert:true actual_expression in
          let reason =
            { actual; actual_expression; expected; name; position }
            |> Node.create_with_default_location
            |> fun mismatch -> Some (Mismatch mismatch)
          in
          NotFound { callable = parse_callable closest; reason }
      | `NotFound (closest, reason) ->
          NotFound { callable = parse_callable closest; reason }
    in
    assert_equal
      ~printer:Signature.show
      ~cmp:Signature.equal
      expected
      signature
  in

  (* Undefined callables always match. *)
  assert_select ~allow_undefined:true "[..., int]" "()" (`Found "[..., int]");
  assert_select ~allow_undefined:true "[..., int]" "(a, b)" (`Found "[..., int]");
  assert_select
    ~allow_undefined:true
    "[..., int]"
    "(a, b='depr', *variable, **keywords)"
    (`Found "[..., int]");
  assert_select
    ~allow_undefined:true
    "[..., unknown][[..., int][[int], int]]"
    "(1)"
    (`Found "[..., int]");

  (* Traverse anonymous arguments. *)
  assert_select "[[], int]" "()" (`Found "[[], int]");

  assert_select "[[int], int]" "()" (`NotFoundMissingArgument "$0");
  assert_select "[[], int]" "(1)" (`NotFoundTooManyArguments (0, 1));

  assert_select "[[int], int]" "(1)" (`Found "[[int], int]");
  assert_select "[[Named(i, int)], int]" "(1)" (`Found "[[Named(i, int)], int]");

  assert_select "[[typing.Any], int]" "(unknown)" (`Found "[[typing.Any], int]");

  assert_select
    "[[int], int]"
    "('string')"
    (`NotFoundMismatch (Type.literal_string "string", "\"string\"", Type.integer, None, 1));
  assert_select "[[int], int]" "(name='string')" (`NotFoundUnexpectedKeyword "name");

  assert_select "[[int], int]" "(*[1])" (`Found "[[int], int]");
  assert_select "[[str], int]"
    "(*[1])"
    (`NotFoundMismatch (Type.integer, "*[1]", Type.string, None, 1));
  assert_select "[[int, str], int]" "(*[1], 'asdf')" (`NotFoundTooManyArguments (2, 3));

  assert_select "[[object], None]" "(union)" (`Found "[[object], None]");
  assert_select
    "[[int], None]"
    "(union)"
    (`NotFoundMismatch (Type.union [Type.integer; Type.string], "union", Type.integer, None, 1));
  assert_select "[[int, Named(i, int)], int]" "(1, 2, i=3)" (`NotFoundTooManyArguments (1, 2));

  (* Traverse variable arguments. *)
  assert_select "[[Variable(variable)], int]" "()" (`Found "[[Variable(variable)], int]");
  assert_select "[[Variable(variable)], int]" "(1, 2)" (`Found "[[Variable(variable)], int]");
  assert_select
    "[[Variable(variable, int)], int]"
    "(1, 2)"
    (`Found "[[Variable(variable, int)], int]");
  assert_select
    "[[Variable(variable, str)], int]"
    "(1, 2)"
    (`NotFoundMismatch (Type.literal_integer 1, "1", Type.string, None, 1));
  assert_select
    "[[Variable(variable, str)], int]"
    "('string', 2)"
    (`NotFoundMismatch (Type.literal_integer 2, "2", Type.string, None, 2));
  assert_select
    "[[Variable(variable, int)], int]"
    "(*[1, 2], 3)"
    (`Found "[[Variable(variable, int)], int]");
  assert_select
    "[[Variable(variable, int), Named(a, str)], int]"
    "(*[1, 2], a='string')"
    (`Found "[[Variable(variable, int), Named(a, str)], int]");
  assert_select
    "[[Variable(variable, int), Named(a, str)], int]"
    "(*[1, 2], *[3, 4], a='string')"
    (`Found "[[Variable(variable, int), Named(a, str)], int]");
  assert_select
    "[[Variable(variable, int)], int]"
    "(*['string'])"
    (`NotFoundMismatch (Type.string, "*[\"string\"]", Type.integer, None, 1));
  (* A single * is special. *)
  assert_select
    "[[Variable($parameter$, int), Named(i, int)], int]"
    "(i=1)"
    (`Found "[[Variable($parameter$, int), Named(i, int)], int]");
  assert_select
    "[[Variable($parameter$, int), Named(i, int)], int]"
    "(2, i=1)"
    (`NotFoundTooManyArguments (0, 1));

  (* Named arguments. *)
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(i=1, j=2)"
    (`Found "[[Named(i, int), Named(j, int)], int]");
  assert_select
    "[[Named(i, int), Named(j, int, default)], int]"
    "(i=1)"
    (`Found "[[Named(i, int), Named(j, int, default)], int]");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(j=1, i=2)"
    (`Found "[[Named(i, int), Named(j, int)], int]");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(j=1, q=2)"
    (`NotFoundUnexpectedKeyword "q");
  assert_select
    "[[], int]"
    "(j=1, q=2)"
    (`NotFoundUnexpectedKeyword "j");
  (* May want new class of error for `keyword argument repeated` *)
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(j=1, j=2, q=3)"
    (`NotFoundUnexpectedKeyword "j");
  assert_select
    "[[Named(i, int), Named(j, int), Named(k, int)], int]"
    "(j=1, a=2, b=3)"
    (`NotFoundUnexpectedKeyword "a");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(j=1, a=2, b=3)"
    (`NotFoundUnexpectedKeyword "a");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(i='string', a=2, b=3)"
    (`NotFoundUnexpectedKeyword "a");
  assert_select
    "[[Named(i, int), Named(j, str)], int]"
    "(i=1, j=2)"
    (`NotFoundMismatch (Type.literal_integer 2, "2", Type.string, Some "j", 2));
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(**{'j': 1, 'i': 2})"
    (`Found "[[Named(i, int), Named(j, int)], int]");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(**{'j': 'string', 'i': 'string'})"
    (`NotFoundMismatch (Type.string, "**{'j': 'string', 'i': 'string'}", Type.integer, None, 1));

  (* Test iterable and mapping expansions. *)
  assert_select
    "[[int], int]" "(*[1])"
    (`Found "[[int], int]");
  assert_select
    "[[int], int]" "(*a)"
    (`NotFoundInvalidVariableArgument (!"a", Type.Top));
  assert_select
    "[[int], int]" "(**a)"
    (`NotFoundInvalidKeywordArgument (!"a", Type.Top));
  assert_select
    "[[int], int]" "(**int_to_int_dictionary)"
    (`NotFoundInvalidKeywordArgument
       (!"int_to_int_dictionary", Type.dictionary ~key:Type.integer ~value:Type.integer));
  assert_select
    "[[int, Named(i, int)], int]"
    "(1, **{'a': 1})"
    (`Found "[[int, Named(i, int)], int]");
  assert_select
    "[[Named(i, int), Named(j, int)], int]"
    "(**{'i': 1}, j=2)"
    (`Found "[[Named(i, int), Named(j, int)], int]");

  (* Constructor resolution. *)
  assert_select
    "[[typing.Callable[[typing.Any], int]], int]"
    "(int)"
    (`Found "[[typing.Callable[[typing.Any], int]], int]");
  assert_select
    "[[typing.Callable[[typing.Any], int]], int]"
    "(str)"
    (`NotFoundMismatch (
        Type.meta Type.string,
        "str",
        Type.Callable.create
          ~parameters:(Type.Callable.Defined [
              Type.Callable.Parameter.Named {
                Type.Callable.Parameter.name = "$0";
                annotation = Type.Any;
                default = false;
              }])
          ~annotation:Type.integer
          (),
        None,
        1));
  (* Keywords. *)
  assert_select "[[Keywords(keywords)], int]" "()" (`Found "[[Keywords(keywords)], int]");
  assert_select "[[Keywords(keywords)], int]" "(a=1, b=2)" (`Found "[[Keywords(keywords)], int]");
  assert_select
    "[[Keywords(keywords, int)], int]"
    "(a=1, b=2)"
    (`Found "[[Keywords(keywords, int)], int]");
  assert_select
    "[[Named(a, int), Named(c, int), Keywords(keywords, int)], int]"
    "(a=1, b=2, c=3)"
    (`Found "[[Named(a, int), Named(c, int), Keywords(keywords, int)], int]");
  assert_select
    "[[Keywords(keywords, str)], int]"
    "(a=1, b=2)"
    (`NotFoundMismatch (Type.literal_integer 1, "1", Type.string, Some "a", 1));
  assert_select
    "[[Keywords(keywords, str)], int]"
    "(a='string', b=2)"
    (`NotFoundMismatch (Type.literal_integer 2, "2", Type.string, Some "b", 2));

  (* Constraint resolution. *)
  assert_select "[[_T], _T]" "(1)" (`Found "[[$literal_one], $literal_one]");
  assert_select
    "[[typing.Callable[[], _T]], _T]"
    "(lambda: 1)"
    (`Found "[[typing.Callable[[], int]], int]");

  assert_select
    "[[_T, _S], _T]" "(1, 'string')"
    (`Found "[[$literal_one, $literal_string], $literal_one]");
  assert_select
    "[[_T, _T], int]"
    "(1, 'string')"
    (`Found "[[typing.Union[int, str], typing.Union[int, str]], int]");
  assert_select
    "[[_T], typing.Union[str, _T]]"
    "(1)"
    (`Found "[[$literal_one], typing.Union[str, $literal_one]]");
  assert_select
    "[[typing.Union[int, typing.List[_T]]], _T]"
    "([1])"
    (`Found "[[typing.Union[int, typing.List[int]]], int]");
  assert_select "[[_T], _S]" "(1)" (`Found "[[$literal_one], ESCAPED[_S]]");

  assert_select "[[typing.List[_T]], int]" "([1])" (`Found "[[typing.List[int]], int]");
  assert_select "[[typing.Sequence[_T]], int]" "([1])" (`Found "[[typing.Sequence[int]], int]");
  assert_select "[[typing.List[C]], int]" "([B()])" (`Found "[[typing.List[C]], int]");
  assert_select
    "[[typing.List[C]], int]"
    "([B() for x in range(3)])"
    (`Found "[[typing.List[C]], int]");
  assert_select "[[typing.Set[C]], int]" "({ B(), B() })" (`Found "[[typing.Set[C]], int]");
  assert_select
    "[[typing.Set[C]], int]"
    "({ B() for x in range(3) })"
    (`Found "[[typing.Set[C]], int]");
  assert_select
    "[[typing.Dict[int, C]], int]"
    "({ 7: B() })"
    (`Found "[[typing.Dict[int, C]], int]");
  assert_select
    "[[typing.Dict[int, C]], int]"
    "({n: B() for n in range(5)})"
    (`Found "[[typing.Dict[int, C]], int]");
  assert_select
    "[[typing.Iterable[typing.Tuple[_T, _S]]], typing.Dict[_T, _S]]"
    "([('a', 1), ('b', 2)])"
    (`Found "[[typing.Iterable[typing.Tuple[str, int]]], typing.Dict[str, int]]");
  assert_select
    "[[typing.Sequence[_T]], int]"
    "(1)"
    (`NotFoundMismatchWithClosest
       ("[[typing.Sequence[ESCAPED[_T]]], int]",
        Type.literal_integer 1, "1",
        Type.parametric "typing.Sequence" [Type.variable "_T"],
        None,
        1));

  assert_select "[[_R], _R]" "(1)" (`Found "[[int], int]");
  assert_select
    "[[_R], _R]"
    "('string')"
    (`NotFoundMismatchWithClosest
       ("[[ESCAPED[_R]], ESCAPED[_R]]", Type.literal_string "string", "\"string\"",
        Type.variable
          ~constraints:(Type.Variable.Explicit [Type.integer; Type.float]) "_R", None, 1));
  assert_select "[[typing.List[_R]], _R]" "([1])" (`Found "[[typing.List[int]], int]");
  assert_select
    "[[typing.List[_R]], _R]"
    "(['string'])"
    (`NotFoundMismatchWithClosest
       ("[[typing.List[ESCAPED[_R]]], ESCAPED[_R]]", Type.list Type.string, "['string']",
        Type.list (Type.variable
                     ~constraints:(Type.Variable.Explicit [Type.integer; Type.float]) "_R"),
        None,
        1));
  assert_select "[[], _R]" "()" (`Found "[[], ESCAPED[_R]]");

  assert_select "[[typing.Type[_T]], _T]" "(int)" (`Found "[[typing.Type[int]], int]");
  assert_select
    "[[typing.Type[typing.List[_T]]], _T]"
    "(meta)"
    (`Found "[[typing.Type[typing.List[int]]], int]");
  assert_select
    "[[typing.Type[_T]], _T]"
    "(typing.List[str])"
    (`Found "[[typing.Type[typing.List[str]]], typing.List[str]]");

  assert_select
    "[[Variable(variable, _T)], int]"
    "(1, 2)"
    (`Found "[[Variable(variable, int)], int]");
  assert_select
    "[[Keywords(keywords, _T)], int]"
    "(a=1, b=2)"
    (`Found "[[Keywords(keywords, int)], int]");

  assert_select
    "[[_T_float_or_str], None]"
    "(union)"
    (`NotFoundMismatchWithClosest
       ("[[ESCAPED[_T_float_or_str]], None]",
        Type.union [Type.integer; Type.string],
        "union",
        Type.variable
          "_T_float_or_str"
          ~constraints:(Type.Variable.Explicit [Type.float; Type.string]),
        None,
        1)
    );
  assert_select
    "[[_T_float_str_or_union], _T_float_str_or_union]"
    "(union)"
    (`Found "[[typing.Union[float, str]], typing.Union[float, str]]");
  assert_select
    "[[_T_bound_by_float_str_union], _T_bound_by_float_str_union]"
    "(union)"
    (`Found "[[typing.Union[int, str]], typing.Union[int, str]]");

  assert_select
    "[[int], _T]"
    "(5)"
    (`Found "[[int], ESCAPED[_T]]");
  assert_select
    "[[int], _T_float_or_str]"
    "(5)"
    (`Found "[[int], ESCAPED[_T_float_or_str]]");
  assert_select
    "[[int], _T_bound_by_float_str_union]"
    "(5)"
    (`Found "[[int], ESCAPED[_T_bound_by_float_str_union]]");

  assert_select
    "[[], _T]"
    "()"
    (`Found "[[], ESCAPED[_T]]");
  assert_select
    "[[], _T_float_or_str]"
    "()"
    (`Found "[[], ESCAPED[_T_float_or_str]]");
  assert_select
    "[[], _T_bound_by_float_str_union]"
    "()"
    (`Found "[[], ESCAPED[_T_bound_by_float_str_union]]");

  (* Ranking. *)
  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[int, int, str], int][[int, str, str], int]]"
    "(0)"
    (* Ambiguous, pick the first one. *)
    (`NotFoundMissingArgumentWithClosest
       ("[[int, int, str], int]", "$1"));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[str], str][[int, str], int]]"
    "(1)"
    (* Ambiguous, prefer the one with the closer arity over the type match. *)
    (`NotFoundMismatchWithClosest
       ("[[str], str]", Type.literal_integer 1, "1", Type.string, None, 1));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[int, Keywords(keywords)], int][[int, str], int]]"
    "(1, 1)" (* Prefer anonymous unmatched parameters over keywords. *)
    (`NotFoundMismatchWithClosest
       ("[[int, str], int]", Type.literal_integer 1, "1", Type.string, None, 2));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[str], str][[], str]]"
    "(1)"
    (`NotFoundMismatchWithClosest
       ("[[str], str]", Type.literal_integer 1, "1", Type.string, None, 1));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[str, Keywords(keywords)], int][[Keywords(keywords)], int]]"
    "(1)" (* Prefer arity matches. *)
    (`NotFoundMismatchWithClosest
       ("[[str, Keywords(keywords)], int]", Type.literal_integer 1, "1", Type.string, None, 1));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[int, int, str], int][[int, str, str], int]]"
    "(0, 'string')"
    (* Clear winner. *)
    (`NotFoundMissingArgumentWithClosest
       ("[[int, str, str], int]",
        "$2"));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[int, str, str, str], int][[int, str, bool], int]]"
    "(0, 'string')"
    (`NotFoundMissingArgumentWithClosest
       ("[[int, str, bool], int]", "$2"));

  (* Match not found in overloads: error against implementation if it exists. *)
  assert_select
    "[[typing.Union[str, int]], typing.Union[str, int]][[[str], str][[int], int]]"
    "(unknown)"
    (`NotFoundMismatch (Type.Top, "unknown", Type.union [Type.integer; Type.string], None, 1));

  assert_select
    "[[bool], bool][[[str], str][[int], int]]"
    "(unknown)"
    (`NotFoundMismatch (Type.Top, "unknown", Type.bool, None, 1));

  assert_select
    "[[bool], bool][[[str, str], str][[int, int], int]]"
    "(unknown)"
    (`NotFoundMismatch (Type.Top, "unknown", Type.bool, None, 1));

  assert_select
    "[[bool], bool][[[str, str], str][[int, int], int]]"
    "(int, str)"
    (`NotFoundTooManyArguments (1, 2));

  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[Named(a, int), Named(b, int)], int][[Named(c, int), Named(d, int)], int]]"
    "(i=1, d=2)"
    (`NotFoundUnexpectedKeywordWithClosest ("[[Named(c, int), Named(d, int)], int]", "i"));

  (* Prefer the overload where the mismatch comes latest *)
  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[int, str], int][[str, int], str]]"
    "(1, 1)"
    (`NotFoundMismatchWithClosest
       ("[[int, str], int]", Type.literal_integer 1, "1", Type.string, None, 2));
  assert_select
    ~allow_undefined:true
    "[..., $unknown][[[str, int], str][[int, str], int]]"
    "(1, 1)"
    (`NotFoundMismatchWithClosest
       ("[[int, str], int]", Type.literal_integer 1, "1", Type.string, None, 2));

  (* Void functions. *)
  assert_select ~allow_undefined:true "[..., None]" "()" (`Found "[..., None]");
  assert_select "[[int], None]" "(1)" (`Found "[[int], None]");
  assert_select
    "[[int], None]"
    "('string')"
    (`NotFoundMismatch (Type.literal_string "string", "\"string\"", Type.integer, None, 1));

  assert_select
    "[[typing.Callable[[_T], bool]], _T]"
    "(g)"
    (`Found "[[typing.Callable[[int], bool]], int]");

  assert_select
    "[[typing.Callable[[_T], typing.List[bool]]], _T]"
    "(f)"
    (`Found "[[typing.Callable[[int], typing.List[bool]]], int]");

  (* Special dictionary constructor *)
  assert_select
    ~name:"dict.__init__"
    "[[Keywords(kwargs, _S)], dict[_T, _S]]"
    "(a=1)"
    (`Found "[[Keywords(kwargs, $literal_one)], dict[str, $literal_one]]");
  (* TODO(T41074174): Error here rather than defaulting back to the initial signature *)
  assert_select
    ~name:"dict.__init__"
    "[[Named(map, typing.Mapping[_T, _S]), Keywords(kwargs, _S)], dict[_T, _S]]"
    "({1: 1}, a=1)"
    (`Found
       ("[[Named(map, typing.Mapping[int, int]), Keywords(kwargs, int)], " ^
        "dict[int, int]]")
    );
  assert_select
    ~name:"dict.__init__"
    "[[Keywords(kwargs, _S)], dict[_T, _S]]"
    "()"
    (`Found "[[Keywords(kwargs, ESCAPED[_S])], dict[ESCAPED[_T], ESCAPED[_S]]]");
  assert_select
    "[[Keywords(kwargs, _S)], dict[_T, _S]]"
    "(a=1)"
    (`Found "[[Keywords(kwargs, $literal_one)], dict[ESCAPED[_T], $literal_one]]");

  ()


let () =
  "signature">:::[
    "select">::test_select;
  ]
  |> Test.run;
