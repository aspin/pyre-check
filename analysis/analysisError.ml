(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Pyre
open Statement


type origin =
  | Class of { annotation: Type.t; class_attribute: bool }
  | Module of Reference.t
[@@deriving compare, eq, show, sexp, hash]


type mismatch = {
  actual: Type.t;
  actual_expressions: Expression.t list;
  expected: Type.t;
  due_to_invariance: bool;
}
[@@deriving compare, eq, show, sexp, hash]


type missing_annotation = {
  name: Reference.t;
  annotation: Type.t option;
  given_annotation: Type.t option;
  evidence_locations: Location.Instantiated.t list;
  thrown_at_source: bool;
}
[@@deriving compare, eq, sexp, show, hash]


type incompatible_type = {
  name: Reference.t;
  mismatch: mismatch;
  declare_location: Location.Instantiated.t;
}
[@@deriving compare, eq, show, sexp, hash]


type invalid_argument =
  | Keyword of { expression: Expression.t; annotation: Type.t }
  | Variable of { expression: Expression.t; annotation: Type.t }
[@@deriving compare, eq, show, sexp, hash]


type precondition_mismatch =
  | Found of mismatch
  | NotFound of Identifier.t
[@@deriving compare, eq, show, sexp, hash]


type override =
  | StrengthenedPrecondition of precondition_mismatch
  | WeakenedPostcondition of mismatch
[@@deriving compare, eq, show, sexp, hash]


type unpack_problem =
  | UnacceptableType of Type.t
  | CountMismatch of int
[@@deriving compare, eq, sexp, show, hash]


type type_variable_origin =
  | ClassToplevel
  | Define
  | Toplevel
[@@deriving compare, eq, sexp, show, hash]


type type_variance_origin =
  | Parameter
  | Return
[@@deriving compare, eq, sexp, show, hash]


type illegal_action_on_incomplete_type =
  | Naming
  | Calling
  | AttributeAccess of Identifier.t
[@@deriving compare, eq, sexp, show, hash]


type kind =
  | AnalysisFailure of Type.t
  | IllegalAnnotationTarget of Expression.t
  | ImpossibleIsinstance of { expression: Expression.t; mismatch: mismatch }
  | IncompatibleAttributeType of { parent: Type.t; incompatible_type: incompatible_type }
  | IncompatibleAwaitableType of Type.t
  | IncompatibleConstructorAnnotation of Type.t
  | IncompatibleParameterType of {
      name: Identifier.t option;
      position: int;
      callee: Reference.t option;
      mismatch: mismatch;
    }
  | IncompatibleReturnType of { mismatch: mismatch; is_implicit: bool; is_unimplemented: bool }
  | IncompatibleVariableType of incompatible_type
  | IncompleteType of {
      target: Access.general_access;
      annotation: Type.t;
      attempted_action: illegal_action_on_incomplete_type;
    }
  | InconsistentOverride of {
      overridden_method: Identifier.t;
      parent: Reference.t;
      override: override;
    }
  | InvalidArgument of invalid_argument
  | InvalidMethodSignature of { annotation: Type.t option; name: Identifier.t }
  | InvalidType of Type.t
  | InvalidTypeParameters of {
      annotation: Type.t;
      expected_number_of_parameters: int;
      given_number_of_parameters: int;
    }
  | InvalidTypeVariable of { annotation: Type.t; origin: type_variable_origin }
  | InvalidTypeVariance of { annotation: Type.t; origin: type_variance_origin }
  | MissingArgument of { callee: Reference.t option; name: Identifier.t }
  | MissingAttributeAnnotation of { parent: Type.t; missing_annotation: missing_annotation }
  | MissingGlobalAnnotation of missing_annotation
  | MissingParameterAnnotation of missing_annotation
  | MissingReturnAnnotation of missing_annotation
  | MutuallyRecursiveTypeVariables of Reference.t option
  | NotCallable of Type.t
  | ProhibitedAny of missing_annotation
  | RedundantCast of Type.t
  | RevealedType of { expression: Expression.t; annotation: Type.t }
  | TooManyArguments of { callee: Reference.t option; expected: int; provided: int }
  | Top
  | TypedDictionaryAccessWithNonLiteral of Identifier.t list
  | TypedDictionaryKeyNotFound of { typed_dictionary_name: Identifier.t; missing_key: string }
  | UndefinedAttribute of { attribute: Identifier.t; origin: origin }
  | UndefinedImport of Reference.t
  | UndefinedName of Reference.t
  | UndefinedType of Type.t
  | UnexpectedKeyword of { name: Identifier.t; callee: Reference.t option }
  | UninitializedAttribute of { name: Identifier.t; parent: Type.t; mismatch: mismatch }
  | Unpack of { expected_count: int; unpack_problem: unpack_problem }
  | UnusedIgnore of int list

  (* Additional errors. *)
  (* TODO(T38384376): split this into a separate module. *)
  | Deobfuscation of Source.t
  | UnawaitedAwaitable of Reference.t
[@@deriving compare, eq, show, sexp, hash]


let code = function
  | RevealedType _ -> -1
  | UnusedIgnore _ -> 0
  | Top -> 1
  | MissingParameterAnnotation _ -> 2
  | MissingReturnAnnotation _ -> 3
  | MissingAttributeAnnotation _ -> 4
  | MissingGlobalAnnotation _ -> 5
  | IncompatibleParameterType _ -> 6
  | IncompatibleReturnType _ -> 7
  | IncompatibleAttributeType _ -> 8
  | IncompatibleVariableType _ -> 9
  | UndefinedType _ -> 11
  | IncompatibleAwaitableType _ -> 12
  | UninitializedAttribute _ -> 13
  | InconsistentOverride { override; _ } ->
      begin
        match override with
        | StrengthenedPrecondition _ -> 14
        | WeakenedPostcondition _ -> 15
      end
  | UndefinedAttribute _ -> 16
  | IncompatibleConstructorAnnotation _ -> 17
  | UndefinedName _ -> 18
  | TooManyArguments _ -> 19
  | MissingArgument _ -> 20
  | UndefinedImport _ -> 21
  | RedundantCast _ -> 22
  | Unpack _ -> 23
  | InvalidTypeParameters _ -> 24
  | ImpossibleIsinstance _ -> 25
  | TypedDictionaryAccessWithNonLiteral _ -> 26
  | TypedDictionaryKeyNotFound _ -> 27
  | UnexpectedKeyword _ -> 28
  | NotCallable _ -> 29
  | AnalysisFailure _ -> 30
  | InvalidType _ -> 31
  | InvalidArgument _ -> 32
  | ProhibitedAny _ -> 33
  | InvalidTypeVariable _ -> 34
  | IllegalAnnotationTarget _ -> 35
  | MutuallyRecursiveTypeVariables _ -> 36
  | InvalidTypeVariance _ -> 35
  | InvalidMethodSignature _ -> 36
  | IncompleteType _ -> 37


  (* Additional errors. *)
  | UnawaitedAwaitable _ -> 101
  | Deobfuscation _ -> 102


let name = function
  | AnalysisFailure _ -> "Analysis failure"
  | Deobfuscation _ -> "Deobfuscation"
  | IllegalAnnotationTarget _ -> "Illegal annotation target"
  | ImpossibleIsinstance _ -> "Impossible isinstance check"
  | IncompatibleAttributeType _ -> "Incompatible attribute type"
  | IncompatibleAwaitableType _ -> "Incompatible awaitable type"
  | IncompatibleConstructorAnnotation _ -> "Incompatible constructor annotation"
  | IncompatibleParameterType _ -> "Incompatible parameter type"
  | IncompatibleReturnType _ -> "Incompatible return type"
  | IncompatibleVariableType _ -> "Incompatible variable type"
  | InconsistentOverride _ -> "Inconsistent override"
  | IncompleteType _ -> "Incomplete Type"
  | InvalidArgument _ -> "Invalid argument"
  | InvalidMethodSignature _ -> "Invalid method signature"
  | InvalidType _ -> "Invalid type"
  | InvalidTypeParameters _ -> "Invalid type parameters"
  | InvalidTypeVariable _ -> "Invalid type variable"
  | InvalidTypeVariance _ -> "Invalid type variance"
  | MissingArgument _ -> "Missing argument"
  | MissingAttributeAnnotation _ -> "Missing attribute annotation"
  | MissingGlobalAnnotation _ -> "Missing global annotation"
  | MissingParameterAnnotation _ -> "Missing parameter annotation"
  | MissingReturnAnnotation _ -> "Missing return annotation"
  | MutuallyRecursiveTypeVariables _ -> "Mutually recursive type variables"
  | NotCallable _ -> "Call error"
  | ProhibitedAny _ -> "Prohibited any"
  | RedundantCast _ -> "Redundant cast"
  | RevealedType _ -> "Revealed type"
  | TooManyArguments _ -> "Too many arguments"
  | Top -> "Undefined error"
  | TypedDictionaryAccessWithNonLiteral _ -> "TypedDict accessed with a non-literal"
  | TypedDictionaryKeyNotFound _ -> "TypedDict accessed with a missing key"
  | UnawaitedAwaitable _ -> "Unawaited awaitable"
  | UndefinedAttribute _ -> "Undefined attribute"
  | UndefinedImport _ -> "Undefined import"
  | UndefinedName _ -> "Undefined name"
  | UndefinedType _ -> "Undefined type"
  | UnexpectedKeyword _ -> "Unexpected keyword"
  | UninitializedAttribute _ -> "Uninitialized attribute"
  | Unpack _ -> "Unable to unpack"
  | UnusedIgnore _ -> "Unused ignore"


let weaken_literals kind =
  let weaken_mismatch { actual; actual_expressions; expected; due_to_invariance } =
    let actual =
      if (Type.contains_literal expected) then
        actual
      else
        Type.weaken_literals actual
    in
    { actual; actual_expressions; expected; due_to_invariance }
  in
  let weaken_missing_annotation = function
    | { given_annotation = Some given; _ } as missing when Type.contains_literal given ->
        missing
    | { annotation = Some annotation; _  } as missing ->
        { missing with annotation = Some (Type.weaken_literals annotation) }
    | missing ->
        missing
  in
  match kind with
  | ImpossibleIsinstance ({ mismatch: mismatch; _ } as isinstance) ->
      ImpossibleIsinstance { isinstance with mismatch = weaken_mismatch mismatch }
  | IncompatibleAttributeType
      ({ incompatible_type = ({ mismatch; _} as incompatible) ; _ } as attribute) ->
      IncompatibleAttributeType {
        attribute with
        incompatible_type = { incompatible with mismatch = weaken_mismatch mismatch };
      }
  | IncompatibleVariableType ({ mismatch; _ } as incompatible) ->
      IncompatibleVariableType { incompatible with mismatch = weaken_mismatch mismatch }
  | InconsistentOverride ({ override = WeakenedPostcondition mismatch; _ } as inconsistent) ->
      InconsistentOverride
        { inconsistent with override = WeakenedPostcondition (weaken_mismatch mismatch) }
  | InconsistentOverride
      ({ override = StrengthenedPrecondition (Found mismatch); _ } as inconsistent) ->
      InconsistentOverride
        { inconsistent with override = StrengthenedPrecondition (Found (weaken_mismatch mismatch)) }
  | IncompatibleParameterType ({ mismatch; _ } as incompatible) ->
      IncompatibleParameterType { incompatible with mismatch = weaken_mismatch mismatch }
  | IncompatibleReturnType ({ mismatch; _ } as incompatible) ->
      IncompatibleReturnType { incompatible with mismatch = weaken_mismatch mismatch }
  | UninitializedAttribute ({ mismatch; _ } as uninitialized) ->
      UninitializedAttribute { uninitialized with mismatch = weaken_mismatch mismatch }
  | MissingAttributeAnnotation { parent; missing_annotation } ->
      MissingAttributeAnnotation
        { parent; missing_annotation = weaken_missing_annotation missing_annotation }
  | MissingGlobalAnnotation missing_annotation ->
      MissingGlobalAnnotation (weaken_missing_annotation missing_annotation)
  | MissingParameterAnnotation missing_annotation ->
      MissingParameterAnnotation (weaken_missing_annotation missing_annotation)
  | MissingReturnAnnotation missing_annotation ->
      MissingReturnAnnotation (weaken_missing_annotation missing_annotation)
  | ProhibitedAny missing_annotation ->
      ProhibitedAny (weaken_missing_annotation missing_annotation)
  | Unpack { expected_count; unpack_problem = UnacceptableType annotation } ->
      Unpack { expected_count; unpack_problem = UnacceptableType (Type.weaken_literals annotation) }
  | IncompatibleAwaitableType annotation ->
      IncompatibleAwaitableType (Type.weaken_literals annotation)
  | NotCallable annotation ->
      NotCallable (Type.weaken_literals annotation)
  | _ ->
      kind


let messages ~concise ~signature location kind =
  let {
    Location.start = { Location.line = start_line; _ };
    Location.stop = { Location.line = stop_line; _ };
    _;
  } = location
  in
  let { Node.value = { Define.name = define_name; _ }; location = define_location } = signature in
  let ordinal number =
    let suffix =
      if (number % 10 = 1) && (number % 100 <> 11) then "st"
      else if (number % 10 = 2) && (number % 100 <> 12) then "nd"
      else if (number % 10 = 3) && (number % 100 <> 13) then "rd"
      else "th"
    in
    (string_of_int number) ^ suffix
  in
  let invariance_message =
    "See https://pyre-check.org/docs/error-types.html#list-and-dictionary-mismatches" ^
    "-with-subclassing for mutable container errors."
  in
  let pp_type = if concise then Type.pp_concise else Type.pp in
  let pp_reference format reference =
    if concise then
      Reference.last reference
      |> Reference.create
      |> Reference.pp_sanitized format
    else
      Reference.pp_sanitized format reference
  in
  let pp_identifier = Identifier.pp_sanitized in
  let kind = weaken_literals kind in
  match kind with
  | AnalysisFailure annotation when concise ->
      [
        Format.asprintf
          "Terminating analysis - type `%a` not defined."
          pp_type annotation
      ]
  | AnalysisFailure annotation ->
      [
        Format.asprintf
          "Terminating analysis because type `%a` is not defined."
          pp_type annotation
      ]
  | Deobfuscation source ->
      [Format.asprintf "\n%a" Source.pp source]
  | IllegalAnnotationTarget _ when concise ->
      ["Target cannot be annotated."]
  | IllegalAnnotationTarget expression ->
      [
        Format.asprintf
          "Target `%a` cannot be annotated."
          Expression.pp_sanitized expression
      ]
  | IncompleteType { target; annotation; attempted_action } ->
      let inferred =
        match annotation with
        | Type.Variable variable when Type.Variable.is_escaped_and_free variable -> ""
        | _ ->  Format.asprintf "`%a` " pp_type annotation
      in
      let consequence =
        match attempted_action with
        | Naming ->
            "add an explicit annotation."
        | Calling ->
            "cannot be called. " ^
            "Separate the expression into an assignment and give it an explicit annotation"
        | AttributeAccess attribute ->
            Format.asprintf
              "so attribute `%s` cannot be accessed. Separate the expression \
               into an assignment and give it an explicit annotation."
              attribute
      in
      [
        Format.asprintf
          "Type %sinferred for `%s` is incomplete, %s"
          inferred
          (Expression.show_sanitized (Node.create_with_default_location (Expression.Access target)))
          consequence
      ]
  | ImpossibleIsinstance _ when concise ->
      ["isinstance check will always fail."]
  | ImpossibleIsinstance { expression; mismatch = { actual; expected; _ } } ->
      let expression_string = Expression.show expression in
      [
        Format.asprintf
          "`%s` has type `%a`, checking if `%s` not isinstance `%a` will always fail."
          expression_string
          pp_type actual
          expression_string
          pp_type expected
      ]
  | IncompatibleAwaitableType actual ->
      [
        (Format.asprintf
           "Expected an awaitable but got `%a`."
           pp_type actual
        );
      ]
  | IncompatibleParameterType {
      name;
      position;
      callee;
      mismatch = { actual; expected; due_to_invariance; _ };
    } ->
      let trace =
        if due_to_invariance then
          [
            Format.asprintf "This call might modify the type of the parameter.";
            invariance_message
          ]
        else
          []
      in
      let target =
        let parameter =
          match name with
          | Some name -> Format.asprintf "parameter `%a`" pp_identifier name
          | _ -> "anonymous parameter"
        in
        let callee =
          match callee with
          | Some callee -> Format.asprintf "call `%a`" pp_reference callee
          | _ -> "anoynmous call"
        in
        if concise then
          Format.asprintf "%s param" (ordinal position)
        else
          Format.asprintf "%s %s to %s" (ordinal position) parameter callee
      in
      Format.asprintf
        "Expected `%a` for %s but got `%a`."
        pp_type expected
        target
        pp_type actual
      :: trace;
  | IncompatibleConstructorAnnotation _ when concise ->
      ["`__init__` should return `None`."]
  | IncompatibleConstructorAnnotation annotation ->
      [
        Format.asprintf
          "`__init__` is annotated as returning `%a`, but it should return `None`."
          pp_type
          annotation;
      ]
  | IncompatibleReturnType
      { mismatch = { actual; expected; due_to_invariance; _ }; is_implicit; _ } ->
      let trace =
        Format.asprintf
          "Type `%a` expected on line %d, specified on line %d.%s"
          pp_type expected
          stop_line
          define_location.Location.start.Location.line
          (if due_to_invariance then " " ^ invariance_message else "")
      in
      let message =
        if is_implicit then
          Format.asprintf
            "Expected `%a` but got implicit return value of `None`."
            pp_type expected
        else
          Format.asprintf
            "Expected `%a` but got `%a`."
            pp_type expected
            pp_type actual
      in
      [message; trace]
  | IncompatibleAttributeType {
      parent;
      incompatible_type = {
        name;
        mismatch = { actual; expected; due_to_invariance; _ };
        declare_location;
      };
    } ->
      let message =
        if concise then
          Format.asprintf
            "Attribute has type `%a`; used as `%a`."
            pp_type expected
            pp_type actual
        else
          Format.asprintf
            "Attribute `%a` declared in class `%a` has type `%a` but is used as type `%a`."
            pp_reference name
            pp_type parent
            pp_type expected
            pp_type actual
      in
      let trace =
        if due_to_invariance then
          invariance_message
        else
          Format.asprintf
            "Attribute `%a` declared on line %d, incorrectly used on line %d."
            pp_reference name
            declare_location.Location.start.Location.line
            start_line
      in
      [message; trace]
  | IncompatibleVariableType {
      name;
      mismatch = { actual; expected; due_to_invariance; _ };
      _;
    } ->
      let message =
        if Type.is_tuple expected && not (Type.is_tuple actual) then
          Format.asprintf "Unable to unpack `%a`, expected a tuple." pp_type actual
        else if concise then
          Format.asprintf
            "%a has type `%a`; used as `%a`."
            pp_reference name
            pp_type expected
            pp_type actual
        else
          Format.asprintf
            "%a is declared to have type `%a` but is used as type `%a`."
            pp_reference name
            pp_type expected
            pp_type actual
      in
      let trace =
        Format.asprintf
          "Redeclare `%a` on line %d if you wish to override the previously declared type.%s"
          pp_reference name
          start_line
          (if due_to_invariance then " " ^ invariance_message else "")
      in
      [message; trace]
  | InconsistentOverride { parent; override; _ } ->
      let detail =
        match override with
        | WeakenedPostcondition { actual; expected; due_to_invariance; _ } ->
            if Type.equal actual Type.Top then
              Format.asprintf
                "The overriding method is not annotated but should return a subtype of `%a`."
                pp_type expected
            else if due_to_invariance then
              invariance_message
            else
              Format.asprintf
                "Returned type `%a` is not a subtype of the overridden return `%a`."
                pp_type actual
                pp_type expected
        | StrengthenedPrecondition (Found { actual; expected; due_to_invariance; _ }) ->
            let extra_detail =
              if due_to_invariance then " " ^ invariance_message else ""
            in
            Format.asprintf
              "Parameter of type `%a` is not a supertype of the overridden parameter `%a`.%s"
              pp_type actual
              pp_type expected
              extra_detail
        | StrengthenedPrecondition (NotFound name) ->
            Format.asprintf
              "Could not find parameter `%a` in overriding signature."
              pp_identifier name
      in
      [
        Format.asprintf
          "`%a` overrides method defined in `%a` inconsistently.%s"
          pp_reference define_name
          pp_reference parent
          (if concise then "" else " " ^ detail)
      ]
  | InvalidArgument argument when concise ->
      begin
        match argument with
        | Keyword _ -> ["Keyword argument must be a mapping with string keys."]
        | Variable _ -> ["Variable argument must be an iterable."]
      end
  | InvalidArgument argument ->
      begin
        match argument with
        | Keyword { expression; annotation } ->
            [
              Format.asprintf
                "Keyword argument `%s` has type `%a` but must be a mapping with string keys."
                (Expression.show_sanitized expression)
                pp_type annotation
            ]
        | Variable { expression; annotation } ->
            [
              Format.asprintf
                "Variable argument `%s` has type `%a` but must be an iterable."
                (Expression.show_sanitized expression)
                pp_type annotation
            ]
      end
  | InvalidMethodSignature { annotation = Some annotation; name; } ->
      [
        Format.asprintf
          "`%a` cannot be the type of `%a`."
          pp_type annotation
          pp_identifier name
      ]
  | InvalidMethodSignature { name; _ } ->
      [
        Format.asprintf
          "Non-static method must specify `%a` parameter."
          pp_identifier name
      ]
  | InvalidType annotation ->
      [
        Format.asprintf
          "Expression `%a` is not a valid type."
          pp_type annotation
      ]
  | InvalidTypeParameters
      { annotation; expected_number_of_parameters; given_number_of_parameters } ->
      if expected_number_of_parameters > 0 then
        let received =
          if given_number_of_parameters = 0 then
            ""
          else
            Format.asprintf ", received %d" given_number_of_parameters
        in
        [
          Format.asprintf
            "Generic type `%a` expects %d type parameter%s%s."
            pp_type annotation
            expected_number_of_parameters
            (if (expected_number_of_parameters = 1) then "" else "s")
            received;
        ]
      else
        [ Format.asprintf "Non-generic type `%a` cannot take parameters." pp_type annotation ]
  | InvalidTypeVariable { annotation; origin } when concise ->
      let format: ('a, Format.formatter, unit, string) format4 =
        match origin with
        | ClassToplevel ->
            "Current class isn't generic over `%a`."
        | Define ->
            "`%a` isn't present in the function's parameters."
        | Toplevel ->
            "`%a` can only be used to annotate generic classes or functions."
      in
      [Format.asprintf format pp_type annotation]
  | InvalidTypeVariable { annotation; origin } ->
      (* The explicit annotation is necessary to appease the compiler. *)
      let format: ('a, Format.formatter, unit, string) format4 =
        match origin with
        | ClassToplevel ->
            "The current class isn't generic with respect to the type variable `%a`."
        | Define ->
            "The type variable `%a` isn't present in the function's parameters."
        | Toplevel ->
            "The type variable `%a` can only be used to annotate generic classes or functions."
      in
      [Format.asprintf format pp_type annotation]
  | InvalidTypeVariance { origin; _ } when concise ->
      begin
        match origin with
        | Parameter -> ["Parameter type cannot be covariant."]
        | Return -> ["Return type cannot be contravariant."]
      end
  | InvalidTypeVariance { annotation; origin } ->
      let format: ('a, Format.formatter, unit, string) format4 =
        match origin with
        | Parameter -> "The type variable `%a` is covariant and cannot be a parameter type."
        | Return -> "The type variable `%a` is contravariant and cannot be a return type."
      in
      [Format.asprintf format pp_type annotation]
  | MissingArgument { name; _ } when concise ->
      [Format.asprintf "Argument `%a` expected." pp_identifier name]
  | MissingArgument { callee; name } ->
      let callee =
        match callee with
        | Some name ->
            Format.asprintf "Call `%a`" pp_reference name
        | _ ->
            "Anonymous call"
      in
      [Format.asprintf "%s expects argument `%a`." callee pp_identifier name]
  | MissingAttributeAnnotation { missing_annotation = { given_annotation; _ }; _ } when concise ->
      if Option.equal Type.equal given_annotation (Some Type.Any) then
        ["Attribute annotation cannot be `Any`."]
      else if given_annotation >>| Type.contains_any |> Option.value ~default:false then
        ["Attribute annotation cannot contain `Any`."]
      else
        ["Attribute must be annotated."]
  | MissingAttributeAnnotation { parent; missing_annotation } ->
      begin
        match missing_annotation with
        | { name; annotation = Some annotation; given_annotation; _ }
          when not (Type.is_concrete annotation) ->
            begin
              match given_annotation with
              | Some given_annotation when Type.equal given_annotation Type.Any ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` must have a type other than `Any`."
                      pp_reference name
                      pp_type parent;
                  ]
              | Some given_annotation when Type.contains_any given_annotation ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` must have a type that does not contain `Any`."
                      pp_reference name
                      pp_type parent;
                  ]
              | _ ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` has no type specified."
                      pp_reference name
                      pp_type parent;
                  ]
            end
        | { name; annotation = Some annotation; evidence_locations; given_annotation; _ } ->
            let trace =
              let evidence_string =
                evidence_locations
                |> List.map ~f:(Format.asprintf "%a" Location.Instantiated.pp_start)
                |> String.concat ~sep:", "
              in
              Format.asprintf
                "Attribute `%a` declared on line %d, type `%a` deduced from %s."
                pp_reference name
                start_line
                pp_type annotation
                evidence_string
            in
            begin
              match given_annotation with
              | Some given_annotation when Type.equal given_annotation Type.Any ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` has type `%a` but type `Any` is specified."
                      pp_reference name
                      pp_type parent
                      pp_type annotation;
                    trace;
                  ]
              | Some given_annotation when Type.contains_any given_annotation ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` is used as type `%a` \
                       and must have a type that does not contain `Any`."
                      pp_reference name
                      pp_type parent
                      pp_type annotation;
                    trace;
                  ]
              | _ ->
                  [
                    Format.asprintf
                      "Attribute `%a` of class `%a` has type `%a` but no type is specified."
                      pp_reference name
                      pp_type parent
                      pp_type annotation;
                    trace;
                  ]
            end
        | { name; annotation = None; _ } ->
            [
              Format.asprintf "Attribute `%a` of class `%a` has no type specified."
                pp_reference name
                pp_type parent;
            ]
      end
  | MissingGlobalAnnotation { given_annotation; _ } when concise ->
      if Option.equal Type.equal given_annotation (Some Type.Any) then
        ["Global annotation cannot be `Any`."]
      else if given_annotation >>| Type.contains_any |> Option.value ~default:false then
        ["Global annotation cannot contain `Any`."]
      else
        ["Global expression must be annotated."]
  | MissingGlobalAnnotation {
      name;
      annotation = Some annotation;
      evidence_locations;
      given_annotation;
      _;
    } when Type.is_concrete annotation ->
      begin
        let evidence_string =
          evidence_locations
          |> List.map ~f:(Format.asprintf "%a" Location.Instantiated.pp_start)
          |> String.concat ~sep:", "
        in
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Globally accessible variable `%a` has type `%a` but type `Any` is specified."
                pp_reference name
                pp_type annotation;
              Format.asprintf
                "Global variable `%a` declared on line %d, type `%a` deduced from %s."
                pp_reference name
                start_line
                pp_type annotation
                evidence_string
            ]
        | Some given_annotation when Type.contains_any given_annotation ->
            [
              Format.asprintf
                "Globally accessible variable `%a` has type `%a` a type must be specified \
                 that does not contain `Any`."
                pp_reference name
                pp_type annotation;
              Format.asprintf
                "Global variable `%a` declared on line %d, type `%a` deduced from %s."
                pp_reference name
                start_line
                pp_type annotation
                evidence_string
            ]
        | _ ->
            [
              Format.asprintf
                "Globally accessible variable `%a` has type `%a` but no type is specified."
                pp_reference name
                pp_type annotation;
              Format.asprintf
                "Global variable `%a` declared on line %d, type `%a` deduced from %s."
                pp_reference name
                start_line
                pp_type annotation
                evidence_string
            ]
      end
  | MissingGlobalAnnotation { name; given_annotation; _ } ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Globally accessible variable `%a` must be specified as type other than `Any`."
                pp_reference name
            ]
        | Some given_annotation when Type.contains_any given_annotation ->
            [
              Format.asprintf
                "Globally accessible variable `%a` must be specified as type that does not contain \
                 `Any`."
                pp_reference name
            ]
        | _ ->
            [
              Format.asprintf
                "Globally accessible variable `%a` has no type specified."
                pp_reference name
            ]
      end
  | MissingParameterAnnotation { given_annotation; _ } when concise ->
      if Option.equal Type.equal given_annotation (Some Type.Any) then
        ["Parameter annotation cannot be `Any`."]
      else if given_annotation >>| Type.contains_any |> Option.value ~default:false then
        ["Parameter annotation cannot contain `Any`."]
      else
        ["Parameter must be annotated."]
  | MissingParameterAnnotation { name; annotation = Some annotation; given_annotation; _ }
    when Type.is_concrete annotation ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Parameter `%a` has type `%a` but type `Any` is specified."
                pp_reference name
                pp_type annotation
            ]
        | Some given_annotation when Type.contains_any given_annotation ->
            [
              Format.asprintf
                "Parameter `%a` is used as type `%a` \
                 and must have a type that does not contain `Any`"
                pp_reference name
                pp_type annotation
            ]
        | _ ->
            [
              Format.asprintf
                "Parameter `%a` has type `%a` but no type is specified."
                pp_reference name
                pp_type annotation
            ]
      end
  | MissingParameterAnnotation { name; given_annotation; _ } ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Parameter `%a` must have a type other than `Any`."
                pp_reference name
            ]
        | Some given_annotation when Type.contains_any given_annotation ->
            [
              Format.asprintf
                "Parameter `%a` must have a type that does not contain `Any`."
                pp_reference name
            ]
        | _ ->
            [
              Format.asprintf
                "Parameter `%a` has no type specified."
                pp_reference name
            ]
      end
  | MissingReturnAnnotation { given_annotation; _ } when concise ->
      if Option.equal Type.equal given_annotation (Some Type.Any) then
        ["Return annotation cannot be `Any`."]
      else if given_annotation >>| Type.contains_any |> Option.value ~default:false then
        ["Return annotation cannot contain `Any`."]
      else
        ["Return type must be annotated."]
  | MissingReturnAnnotation {
      annotation = Some annotation;
      evidence_locations;
      given_annotation;
      _;
    }
    when Type.is_concrete annotation ->
      let trace =
        let evidence_string =
          evidence_locations
          |> List.map ~f:(Format.asprintf "%a" Location.Instantiated.pp_line)
          |> String.concat ~sep:", "
        in
        Format.asprintf
          "Type `%a` was returned on %s %s, return type should be specified on line %d."
          pp_type annotation
          (if (List.length evidence_locations) > 1 then "lines" else "line")
          evidence_string
          start_line
      in
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              (Format.asprintf
                 "Returning `%a` but type `Any` is specified."
                 pp_type annotation);
              trace;
            ]
        | Some given_annotation when Type.contains_any given_annotation ->
            [
              (Format.asprintf
                 "Returning `%a` but return type must be specified as type \
                  that does not contain `Any`."
                 pp_type annotation);
              trace;
            ]
        | _ ->
            [
              (Format.asprintf
                 "Returning `%a` but no return type is specified."
                 pp_type annotation);
              trace;
            ]
      end
  | MissingReturnAnnotation { given_annotation; _ } ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            ["Return type must be specified as type other than `Any`."]
        | Some given_annotation when Type.contains_any given_annotation ->
            ["Return type must be specified as type that does not contain `Any`."]
        | _ ->
            ["Return type is not specified."]
      end
  | MutuallyRecursiveTypeVariables callee ->
      let callee =
        match callee with
        | Some callee ->
            Format.asprintf "call `%a`" pp_reference callee
        | _ ->
            "anoynmous call"
      in
      [ Format.asprintf "Solving type variables for %s led to infinite recursion" callee ]
  | NotCallable annotation ->
      [ Format.asprintf "`%a` is not a function." pp_type annotation ]

  | ProhibitedAny { given_annotation; _ } when concise ->
      if given_annotation >>| Type.equal Type.Any |> Option.value ~default:false then
        ["Given annotation cannot be `Any`."]
      else
        ["Given annotation cannot contain `Any`."]
  | ProhibitedAny { name; annotation = Some annotation; given_annotation; _ }
    when Type.is_concrete annotation ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Expression `%a` has type `%a`; given explicit type cannot be `Any`."
                pp_reference name
                pp_type annotation
            ]
        | _ ->
            [
              Format.asprintf
                "Expression `%a` is used as type `%a`; given explicit type cannot contain `Any`."
                pp_reference name
                pp_type annotation
            ]
      end
  | ProhibitedAny { name; given_annotation; _ } ->
      begin
        match given_annotation with
        | Some given_annotation when Type.equal given_annotation Type.Any ->
            [
              Format.asprintf
                "Explicit annotation for `%a` cannot be `Any`."
                pp_reference name
            ]
        | _ ->
            [
              Format.asprintf
                "Explicit annotation for `%a` cannot contain `Any`."
                pp_reference name
            ]
      end
  | RedundantCast _ when concise ->
      ["The cast is redundant."]
  | RedundantCast annotation ->
      [
        Format.asprintf
          "The value being cast is already of type `%a`."
          pp_type annotation;
      ]
  | RevealedType { expression; annotation } ->
      [
        Format.asprintf
          "Revealed type for `%s` is `%a`."
          (Expression.show_sanitized expression)
          pp_type annotation;
      ]
  | TooManyArguments { expected; _ } when concise ->
      [
        Format.asprintf "Expected %d positional argument%s."
          expected
          (if expected <> 1 then "s" else "");
      ]
  | TooManyArguments { callee; expected; provided } ->
      let callee =
        match callee with
        | Some name -> Format.asprintf "Call `%a`" pp_reference name
        | _ -> "Anonymous call"
      in
      [
        Format.asprintf "%s expects %d positional argument%s, %d %s provided."
          callee
          expected
          (if expected <> 1 then "s" else "")
          provided
          (if provided > 1 then "were" else "was");
      ]
  | Top ->
      [ "Problem with analysis." ]
  | TypedDictionaryAccessWithNonLiteral acceptable_keys ->
      let explanation =
        let acceptable_keys =
          List.map acceptable_keys ~f:(Format.sprintf "'%s'")
          |> String.concat ~sep:", "
        in
        (* Use heuristic to limit message from going crazy. *)
        if not concise && String.length acceptable_keys < 80 then
          Format.asprintf " Expected one of (%s)." acceptable_keys
        else
          ""
      in
      [
        Format.asprintf
          "TypedDict key must be a string literal.%s"
          explanation
      ]
  | TypedDictionaryKeyNotFound { typed_dictionary_name; missing_key } ->
      if String.equal typed_dictionary_name "$anonymous" then
        [ Format.asprintf "TypedDict has no key `%s`." missing_key ]
      else
        [
          Format.asprintf
            "TypedDict `%a` has no key `%s`."
            String.pp typed_dictionary_name
            missing_key
        ]
  | Unpack { expected_count; unpack_problem } ->
      begin
        match unpack_problem with
        | UnacceptableType bad_type ->
            [Format.asprintf
               "Unable to unpack `%a` into %d values."
               pp_type
               bad_type
               expected_count]
        | CountMismatch actual_count ->
            let value_message =
              if actual_count = 1 then
                "single value"
              else
                Format.sprintf "%d values" actual_count
            in
            [Format.sprintf "Unable to unpack %s, %d were expected." value_message expected_count]
      end
  | UnawaitedAwaitable name ->
      [
        Format.asprintf "`%a` is never awaited." pp_reference name;
        Format.asprintf "`%a` is defined on line %d" pp_reference name start_line;
      ]
  | UndefinedAttribute { attribute; origin } ->
      let target =
        match origin with
        | Class { annotation; _ } ->
            let annotation, _ = Type.split annotation in
            let name =
              if Type.is_optional_primitive annotation then
                "Optional type"
              else
                Format.asprintf "`%a`" pp_type annotation
            in
            name
        | Module access ->
            (Format.asprintf "Module `%a`" pp_reference access)
      in
      let trace =
        match origin with
        | Class { class_attribute; _ } when class_attribute ->
            [
              "This attribute is accessed as a class variable; did you mean to declare it with " ^
              "`typing.ClassVar`?";
            ]
        | _ ->
            []
      in
      [Format.asprintf "%s has no attribute `%a`." target pp_identifier attribute]
      @ trace
  | UndefinedName access when concise ->
      [Format.asprintf "Global name `%a` is undefined." pp_reference access]
  | UndefinedName access ->
      [
        Format.asprintf
          "Global name `%a` is not defined, or there is at least one control flow path that \
           doesn't define `%a`."
          pp_reference access
          pp_reference access;
      ]
  | UndefinedImport access when concise ->
      [Format.asprintf "Could not find `%a`." pp_reference access]
  | UndefinedImport access ->
      [
        Format.asprintf
          "Could not find a module corresponding to import `%a`."
          pp_reference access;
      ]
  | UndefinedType annotation ->
      [
        Format.asprintf
          "Type `%a` is not defined."
          pp_type annotation
      ]
  | UnexpectedKeyword { name; _ } when concise ->
      [
        Format.asprintf
          "Unexpected keyword argument `%s`."
          (Identifier.sanitized name)
      ]
  | UnexpectedKeyword { name; callee } ->
      let callee =
        match callee with
        | Some name -> Format.asprintf "call `%a`" pp_reference name
        | _ -> "anonymous call"
      in
      [
        Format.asprintf
          "Unexpected keyword argument `%s` to %s."
          (Identifier.sanitized name)
          callee
      ]
  | UninitializedAttribute { name; parent; mismatch = { actual; expected; _ } } ->
      let message =
        if concise then
          Format.asprintf "Attribute `%a` is never initialized." pp_identifier name
        else
          Format.asprintf
            "Attribute `%a` is declared in class `%a` to have type `%a` but is never \
             initialized."
            pp_identifier name
            pp_type parent
            pp_type expected
      in
      [
        message;
        (Format.asprintf
           "Attribute `%a` is declared on line %d, never initialized and therefore must be `%a`."
           pp_identifier name
           start_line
           pp_type actual)
      ]
  | UnusedIgnore codes ->
      let string_from_codes codes =
        if List.length codes > 0 then
          List.map codes ~f:Int.to_string
          |> String.concat ~sep:", "
          |> Format.asprintf "[%s] "
        else
          ""
      in
      let plural = List.length codes > 1 in
      [
        Format.asprintf
          "Pyre ignore%s %s%s extraneous."
          (if plural then "s" else "")
          (string_from_codes codes)
          (if plural then "are" else "is")
      ]


let inference_information
    ~signature:
    {
      Node.value = {
        Define.name;
        parameters;
        return_annotation;
        decorators;
        parent;
        async;
        _
      };
      _
    }
    kind =
  let print_annotation annotation =
    Format.asprintf "`%a`" Type.pp annotation
    |> String.strip ~drop:(Char.equal '`')
  in
  let parameters =
    let to_json { Node.value = { Parameter.name; annotation; value }; _ } =
      let annotation =
        match kind with
        | MissingParameterAnnotation {
            name = parameter_name;
            annotation = Some parameter_annotation;
            _;
          }
          when Reference.equal_sanitized (Reference.create name) parameter_name ->
            parameter_annotation
            |> print_annotation
            |> (fun string -> `String string)
        | _ ->
            annotation
            >>| Expression.show
            >>| (fun string -> `String string)
            |> Option.value ~default:`Null
      in
      let value =
        value
        >>| Expression.show
        >>| (fun string -> `String string)
        |> Option.value ~default:`Null
      in
      `Assoc [
        "name", `String (Identifier.sanitized name);
        "type", annotation;
        "value", value
      ]
    in
    List.map parameters ~f:to_json
  in
  let decorators =
    let decorator_to_json decorator = `String (Expression.show decorator) in
    List.map decorators ~f:decorator_to_json
  in
  let print_parent parent =
    parent
    >>| Reference.show_sanitized
    >>| (fun string -> `String string)
    |> Option.value ~default:`Null
  in
  let function_name = Reference.show_sanitized name in
  match kind with
  | MissingReturnAnnotation { annotation = Some annotation; _ } ->
      `Assoc [
        "annotation", `String (print_annotation annotation);
        "parent", print_parent parent;
        "function_name", `String function_name;
        "parameters", `List parameters;
        "decorators", `List decorators;
        "async", `Bool async;
      ]
  | MissingParameterAnnotation _ ->
      let return_annotation =
        return_annotation
        >>| Format.asprintf "%a" Expression.pp
        >>| (fun string -> `String string)
        |> Option.value ~default:`Null
      in
      `Assoc [
        "annotation", return_annotation;
        "parent", print_parent parent;
        "function_name", `String function_name;
        "parameters", `List parameters;
        "decorators", `List decorators;
        "async", `Bool async;
      ]
  | MissingAttributeAnnotation { parent; missing_annotation = { name; annotation; _ } } ->
      let attributes =
        [
          "parent", `String (Type.show parent);
          "attribute_name", `String (Reference.show_sanitized name);
        ]
      in
      begin
        match annotation with
        | Some annotation ->
            `Assoc (("annotation", `String (print_annotation annotation)) :: attributes)
        | None ->
            `Assoc attributes
      end
  | MissingGlobalAnnotation { name; annotation; _ } ->
      let attributes =
        [
          "parent", `Null;
          "attribute_name", `String (Reference.show_sanitized name);
        ]
      in
      begin
        match annotation with
        | Some annotation ->
            `Assoc (("annotation", `String (print_annotation annotation)) :: attributes)
        | None ->
            `Assoc attributes
      end
  | _ -> `Assoc []


include BaseError.Make(struct
    type t = kind
    let compare = compare_kind
    let hash = hash_kind
    let show = show_kind
    let hash_fold_t = hash_fold_kind
    let sexp_of_t = sexp_of_kind
    let t_of_sexp = kind_of_sexp
    let pp = pp_kind
    let equal = equal_kind

    let code = code
    let name = name
    let messages = messages
    let inference_information = inference_information
  end)


module IntSet = Set.Make(struct
    type nonrec t = Int.t
    let compare = Int.compare
    let sexp_of_t = Int.sexp_of_t
    let t_of_sexp = Int.t_of_sexp
  end)


module Set = Set.Make(struct
    type nonrec t = t
    let compare = compare
    let sexp_of_t = sexp_of_t
    let t_of_sexp = t_of_sexp
  end)


let due_to_analysis_limitations { kind; _ } =
  match kind with
  | ImpossibleIsinstance { mismatch = { actual; _ }; _ }
  | IncompatibleAwaitableType actual
  | IncompatibleParameterType { mismatch = { actual; _ }; _ }
  | IncompatibleReturnType { mismatch = { actual; _ }; _ }
  | IncompatibleAttributeType { incompatible_type = { mismatch = { actual; _ }; _ }; _ }
  | IncompatibleVariableType { mismatch = { actual; _ }; _ }
  | InconsistentOverride { override = StrengthenedPrecondition (Found { actual; _ }); _ }
  | InconsistentOverride { override = WeakenedPostcondition { actual; _ }; _ }
  | InvalidArgument (Keyword { annotation = actual; _ })
  | InvalidArgument (Variable { annotation = actual; _ })
  | InvalidType actual
  | InvalidTypeParameters { annotation = actual; _ }
  | NotCallable actual
  | ProhibitedAny { given_annotation = Some actual; _ }
  | RedundantCast actual
  | UninitializedAttribute { mismatch = {actual; _ }; _ }
  | Unpack { unpack_problem = UnacceptableType actual; _ } ->
      Type.is_unknown actual ||
      Type.is_unbound actual ||
      Type.is_type_alias actual
  | Top -> true
  | UndefinedAttribute { origin = Class { annotation; _ }; _ } ->
      Type.is_unknown annotation
  | AnalysisFailure _
  | Deobfuscation _
  | IllegalAnnotationTarget _
  | IncompatibleConstructorAnnotation _
  | InconsistentOverride { override = StrengthenedPrecondition (NotFound _); _ }
  | InvalidMethodSignature _
  | InvalidTypeVariable _
  | InvalidTypeVariance _
  | IncompleteType _
  | MissingArgument _
  | MissingAttributeAnnotation _
  | MissingGlobalAnnotation _
  | MissingParameterAnnotation _
  | MissingReturnAnnotation _
  | MutuallyRecursiveTypeVariables _
  | ProhibitedAny _
  | TooManyArguments _
  | TypedDictionaryAccessWithNonLiteral _
  | TypedDictionaryKeyNotFound _
  | Unpack _
  | RevealedType _
  | UnawaitedAwaitable _
  | UndefinedAttribute _
  | UndefinedName _
  | UndefinedImport _
  | UndefinedType _
  | UnexpectedKeyword _
  | UnusedIgnore _ ->
      false


let due_to_builtin_import { kind; _ } =
  match kind with
  | UndefinedImport import ->
      String.equal (Reference.show import) "builtins"
  | _ ->
      false


let due_to_mismatch_with_any resolution { kind; _ } =
  let is_consistent_with ~actual ~expected =
    (Type.contains_any actual || Type.contains_any expected) &&
    Resolution.consistent_solution_exists resolution actual expected
  in
  match kind with
  | IncompatibleAwaitableType actual
  | InvalidArgument (Variable { annotation = actual; _ })
  | NotCallable actual
  | UndefinedAttribute { origin = Class { annotation = actual; _ }; _ }
  | Unpack { unpack_problem = UnacceptableType actual; _ } ->
      Type.equal actual Type.Any
  | ImpossibleIsinstance { mismatch = { actual; actual_expressions; expected; _ }; _ }
  | InconsistentOverride
      { override = StrengthenedPrecondition (Found { actual; actual_expressions; expected; _ }); _ }
  | InconsistentOverride
      { override = WeakenedPostcondition { actual; actual_expressions; expected; _ }; _ }
  | IncompatibleParameterType { mismatch = { actual; actual_expressions; expected; _ }; _ }
  | IncompatibleReturnType { mismatch = { actual; actual_expressions; expected; _ }; _ }
  | IncompatibleAttributeType
      { incompatible_type = { mismatch = { actual; actual_expressions; expected; _ }; _ }; _ }
  | IncompatibleVariableType { mismatch = { actual; actual_expressions; expected; _ }; _ }
  | UninitializedAttribute { mismatch = { actual; actual_expressions; expected; _ }; _ } ->
      let consistent () =
        let expressions =
          match actual_expressions with
          | [] -> [None]
          | expressions -> List.map expressions ~f:Option.some
        in
        let check_consistent sofar expression =
          sofar && Resolution.is_consistent_with resolution actual expected ~expression
        in
        List.fold expressions ~init:true ~f:check_consistent
      in
      (Type.contains_any actual || Type.contains_any expected) && consistent ()
  | InvalidArgument (Keyword { annotation = actual; _ }) ->
      is_consistent_with
        ~actual
        ~expected:(Type.parametric "typing.Mapping" [Type.string; Type.Top])
  | AnalysisFailure _
  | Deobfuscation _
  | IllegalAnnotationTarget _
  | IncompatibleConstructorAnnotation _
  | InconsistentOverride _
  | IncompleteType _
  | InvalidMethodSignature _
  | InvalidType _
  | InvalidTypeParameters _
  | InvalidTypeVariable _
  | InvalidTypeVariance _
  | MissingAttributeAnnotation _
  | MissingGlobalAnnotation _
  | MissingParameterAnnotation _
  | MissingReturnAnnotation _
  | MutuallyRecursiveTypeVariables _
  | ProhibitedAny _
  | RedundantCast _
  | RevealedType _
  | TooManyArguments _
  | Top
  | TypedDictionaryAccessWithNonLiteral _
  | TypedDictionaryKeyNotFound _
  | UndefinedType _
  | UnexpectedKeyword _
  | MissingArgument _
  | UnawaitedAwaitable _
  | UndefinedAttribute _
  | UndefinedName _
  | UndefinedImport _
  | Unpack _
  | UnusedIgnore _ ->
      false


let less_or_equal ~resolution left right =
  let less_or_equal_mismatch left right =
    Resolution.less_or_equal resolution ~left:left.actual ~right:right.actual &&
    Resolution.less_or_equal resolution ~left:left.expected ~right:right.expected
  in
  Location.Instantiated.equal left.location right.location &&
  begin
    match left.kind, right.kind with
    | AnalysisFailure left, AnalysisFailure right ->
        Type.equal left right
    | Deobfuscation left, Deobfuscation right ->
        Source.equal left right
    | IllegalAnnotationTarget left, IllegalAnnotationTarget right ->
        Expression.equal left right
    | ImpossibleIsinstance left, ImpossibleIsinstance right
      when Expression.equal left.expression right.expression ->
        less_or_equal_mismatch left.mismatch right.mismatch
    | IncompatibleAwaitableType left, IncompatibleAwaitableType right ->
        Resolution.less_or_equal resolution ~left ~right
    | IncompatibleParameterType left, IncompatibleParameterType right
      when Option.equal Identifier.equal_sanitized left.name right.name ->
        less_or_equal_mismatch left.mismatch right.mismatch
    | IncompatibleConstructorAnnotation left, IncompatibleConstructorAnnotation right ->
        Resolution.less_or_equal resolution ~left ~right
    | IncompatibleReturnType left, IncompatibleReturnType right ->
        less_or_equal_mismatch left.mismatch right.mismatch
    | IncompleteType
        { target = left_target; annotation = left; attempted_action = left_attempted_action },
      IncompleteType
        { target = right_target; annotation = right; attempted_action = right_attempted_action }
      when Access.equal_general_access left_target right_target &&
           equal_illegal_action_on_incomplete_type left_attempted_action right_attempted_action ->
        Resolution.less_or_equal resolution ~left ~right
    | IncompatibleAttributeType left, IncompatibleAttributeType right
      when Type.equal left.parent right.parent &&
           Reference.equal left.incompatible_type.name right.incompatible_type.name ->
        less_or_equal_mismatch left.incompatible_type.mismatch right.incompatible_type.mismatch
    | IncompatibleVariableType left, IncompatibleVariableType right
      when Reference.equal left.name right.name ->
        less_or_equal_mismatch left.mismatch right.mismatch
    | InconsistentOverride left, InconsistentOverride right ->
        begin
          match left.override, right.override with
          | StrengthenedPrecondition (NotFound left_access),
            StrengthenedPrecondition (NotFound right_access) ->
              Identifier.equal_sanitized left_access right_access
          | StrengthenedPrecondition (Found left_mismatch),
            StrengthenedPrecondition (Found right_mismatch)
          | WeakenedPostcondition left_mismatch, WeakenedPostcondition right_mismatch ->
              less_or_equal_mismatch left_mismatch right_mismatch
          | _ ->
              false
        end
    | InvalidArgument (Keyword left), InvalidArgument (Keyword right)
      when Expression.equal left.expression right.expression ->
        Resolution.less_or_equal resolution ~left:left.annotation ~right:right.annotation
    | InvalidArgument (Variable left), InvalidArgument (Variable right)
      when Expression.equal left.expression right.expression ->
        Resolution.less_or_equal resolution ~left:left.annotation ~right:right.annotation
    | InvalidMethodSignature left, InvalidMethodSignature right ->
        begin
          match left.annotation, right.annotation with
          | Some left, Some right ->
              Resolution.less_or_equal resolution ~left ~right
          | None, None ->
              true
          | _ ->
              false
        end
    | InvalidType left, InvalidType right ->
        Resolution.less_or_equal resolution ~left ~right
    | InvalidTypeParameters {
        annotation = left;
        expected_number_of_parameters = left_expected;
        given_number_of_parameters = left_given;
      },
      InvalidTypeParameters {
        annotation = right;
        expected_number_of_parameters = right_expected;
        given_number_of_parameters = right_given;
      }
      when left_expected = right_expected && left_given = right_given ->
        Resolution.less_or_equal resolution ~left ~right
    | InvalidTypeVariable { annotation = left; origin = left_origin },
      InvalidTypeVariable { annotation = right; origin = right_origin } ->
        Resolution.less_or_equal resolution ~left ~right &&
        equal_type_variable_origin left_origin right_origin
    | InvalidTypeVariance { annotation = left; origin = left_origin },
      InvalidTypeVariance { annotation = right; origin = right_origin } ->
        Resolution.less_or_equal resolution ~left ~right &&
        equal_type_variance_origin left_origin right_origin
    | MissingArgument left, MissingArgument right ->
        Option.equal Reference.equal_sanitized left.callee right.callee &&
        Identifier.equal_sanitized left.name right.name
    | ProhibitedAny left, ProhibitedAny right
    | MissingParameterAnnotation left, MissingParameterAnnotation right
    | MissingReturnAnnotation left, MissingReturnAnnotation right
    | MissingAttributeAnnotation { missing_annotation = left; _ },
      MissingAttributeAnnotation { missing_annotation = right; _ }
    | MissingGlobalAnnotation left, MissingGlobalAnnotation right
      when (Reference.equal_sanitized left.name right.name) ->
        begin
          match left.annotation, right.annotation with
          | Some left, Some right ->
              Resolution.less_or_equal resolution ~left ~right
          | None, None ->
              true
          | _ ->
              false
        end
    | NotCallable left, NotCallable right ->
        Resolution.less_or_equal resolution ~left ~right
    | RedundantCast left, RedundantCast right ->
        Resolution.less_or_equal resolution ~left ~right
    | RevealedType left, RevealedType right ->
        Expression.equal left.expression right.expression &&
        Resolution.less_or_equal resolution ~left:left.annotation ~right:right.annotation
    | TooManyArguments left, TooManyArguments right ->
        Option.equal Reference.equal_sanitized left.callee right.callee &&
        left.expected = right.expected &&
        left.provided = right.provided
    | UninitializedAttribute left, UninitializedAttribute right
      when String.equal left.name right.name ->
        less_or_equal_mismatch left.mismatch right.mismatch
    | UnawaitedAwaitable left, UnawaitedAwaitable right ->
        Reference.equal_sanitized left right
    | UndefinedAttribute left, UndefinedAttribute right
      when Identifier.equal_sanitized left.attribute right.attribute ->
        begin
          match left.origin, right.origin with
          | Class left, Class right when left.class_attribute = right.class_attribute ->
              Resolution.less_or_equal resolution ~left:left.annotation ~right:right.annotation
          | Module left, Module right ->
              Reference.equal_sanitized left right
          | _ ->
              false
        end
    | UndefinedName left, UndefinedName right when Reference.equal_sanitized left right ->
        true
    | UndefinedType left, UndefinedType right ->
        Type.equal left right
    | UnexpectedKeyword left, UnexpectedKeyword right ->
        Option.equal Reference.equal_sanitized left.callee right.callee &&
        Identifier.equal left.name right.name
    | UndefinedImport left, UndefinedImport right ->
        Reference.equal_sanitized left right
    | UnusedIgnore left, UnusedIgnore right ->
        IntSet.is_subset (IntSet.of_list left) ~of_:(IntSet.of_list right)
    | Unpack { expected_count = left_count; unpack_problem = left_problem },
      Unpack { expected_count = right_count; unpack_problem = right_problem } ->
        left_count = right_count &&
        begin
          match left_problem, right_problem with
          | UnacceptableType left, UnacceptableType right ->
              Resolution.less_or_equal resolution ~left ~right
          | CountMismatch left, CountMismatch right ->
              left = right
          | _ ->
              false
        end
    | _, Top -> true
    | AnalysisFailure _, _
    | Deobfuscation _, _
    | IllegalAnnotationTarget _, _
    | ImpossibleIsinstance _, _
    | IncompatibleAttributeType _, _
    | IncompatibleAwaitableType _, _
    | IncompatibleConstructorAnnotation _, _
    | IncompatibleParameterType _, _
    | IncompatibleReturnType _, _
    | IncompleteType _, _
    | IncompatibleVariableType _, _
    | InconsistentOverride _, _
    | InvalidArgument _, _
    | InvalidMethodSignature _, _
    | InvalidType _, _
    | InvalidTypeParameters _, _
    | InvalidTypeVariable _, _
    | InvalidTypeVariance _, _
    | MissingArgument _, _
    | MissingAttributeAnnotation _, _
    | MissingGlobalAnnotation _, _
    | MissingParameterAnnotation _, _
    | MissingReturnAnnotation _, _
    | MutuallyRecursiveTypeVariables _, _
    | NotCallable _, _
    | ProhibitedAny _, _
    | RedundantCast _, _
    | RevealedType _, _
    | TooManyArguments _, _
    | Top, _
    | TypedDictionaryAccessWithNonLiteral _, _
    | TypedDictionaryKeyNotFound _, _
    | UnawaitedAwaitable _, _
    | UndefinedAttribute _, _
    | UndefinedImport _, _
    | UndefinedName _, _
    | UndefinedType _, _
    | UnexpectedKeyword _, _
    | UninitializedAttribute _, _
    | Unpack _, _
    | UnusedIgnore _, _ ->
        false
  end


let join ~resolution left right =
  let join_mismatch left right =
    {
      expected = Resolution.join resolution left.expected right.expected;
      actual = Resolution.join resolution left.actual right.actual;
      actual_expressions = left.actual_expressions @ right.actual_expressions;
      due_to_invariance = left.due_to_invariance || right.due_to_invariance;
    }
  in
  let join_missing_annotation
      (left: missing_annotation)  (* Ohcaml... *)
      (right: missing_annotation): missing_annotation =
    let join_annotation_options =
      Option.merge ~f:(Resolution.join resolution)
    in
    {
      left with
      annotation = join_annotation_options left.annotation right.annotation;
      given_annotation = join_annotation_options left.given_annotation right.given_annotation;
      evidence_locations =
        List.dedup_and_sort
          ~compare:Location.Instantiated.compare
          (left.evidence_locations @ right.evidence_locations);
      thrown_at_source = left.thrown_at_source || right.thrown_at_source;
    }
  in
  let kind =
    match left.kind, right.kind with
    | AnalysisFailure left, AnalysisFailure right ->
        AnalysisFailure (Type.union [left; right])
    | Deobfuscation left, Deobfuscation right when Source.equal left right ->
        Deobfuscation left
    | IllegalAnnotationTarget left, IllegalAnnotationTarget right
      when Expression.equal left right ->
        IllegalAnnotationTarget left
    | IncompatibleAwaitableType left, IncompatibleAwaitableType right ->
        IncompatibleAwaitableType (Resolution.join resolution left right)
    | IncompleteType
        { target = left_target; annotation = left; attempted_action = left_attempted_action },
      IncompleteType
        { target = right_target; annotation = right; attempted_action = right_attempted_action }
      when Access.equal_general_access left_target right_target &&
           equal_illegal_action_on_incomplete_type left_attempted_action right_attempted_action ->
        IncompleteType {
          target = left_target;
          annotation = Resolution.join resolution left right;
          attempted_action = left_attempted_action;
        }
    | InvalidTypeParameters {
        annotation = left;
        expected_number_of_parameters = left_expected;
        given_number_of_parameters = left_given;
      },
      InvalidTypeParameters {
        annotation = right;
        expected_number_of_parameters = right_expected;
        given_number_of_parameters = right_given;
      }
      when left_expected = right_expected && left_given = right_given ->
        InvalidTypeParameters {
          annotation = Resolution.join resolution left right;
          expected_number_of_parameters = left_expected;
          given_number_of_parameters = left_given;
        }
    | MissingArgument left, MissingArgument right
      when Option.equal Reference.equal_sanitized left.callee right.callee &&
           Identifier.equal_sanitized left.name right.name ->
        MissingArgument left
    | MissingParameterAnnotation left, MissingParameterAnnotation right
      when Reference.equal_sanitized left.name right.name ->
        MissingParameterAnnotation (join_missing_annotation left right)
    | MissingReturnAnnotation left, MissingReturnAnnotation right ->
        MissingReturnAnnotation (join_missing_annotation left right)
    | MissingAttributeAnnotation left, MissingAttributeAnnotation right
      when (Reference.equal_sanitized left.missing_annotation.name right.missing_annotation.name) &&
           Type.equal left.parent right.parent ->
        MissingAttributeAnnotation {
          parent = left.parent;
          missing_annotation =
            join_missing_annotation
              left.missing_annotation
              right.missing_annotation;
        }
    | MissingGlobalAnnotation left, MissingGlobalAnnotation right
      when Reference.equal_sanitized left.name right.name ->
        MissingGlobalAnnotation (join_missing_annotation left right)
    | NotCallable left, NotCallable right ->
        NotCallable (Resolution.join resolution left right)
    | ProhibitedAny left, ProhibitedAny right ->
        ProhibitedAny (join_missing_annotation left right)
    | RedundantCast left, RedundantCast right ->
        RedundantCast (Resolution.join resolution left right)
    | RevealedType left, RevealedType right
      when Expression.equal left.expression right.expression ->
        RevealedType {
          left with
          annotation = Resolution.join resolution left.annotation right.annotation;
        }
    | IncompatibleParameterType left, IncompatibleParameterType right
      when Option.equal Identifier.equal_sanitized left.name right.name &&
           left.position = right.position &&
           Option.equal Reference.equal_sanitized left.callee right.callee ->
        IncompatibleParameterType {
          left with mismatch = join_mismatch left.mismatch right.mismatch
        }
    | IncompatibleConstructorAnnotation left, IncompatibleConstructorAnnotation right ->
        IncompatibleConstructorAnnotation (Resolution.join resolution left right)
    | IncompatibleReturnType left, IncompatibleReturnType right ->
        IncompatibleReturnType {
          mismatch = join_mismatch left.mismatch right.mismatch;
          is_implicit = left.is_implicit && right.is_implicit;
          is_unimplemented = left.is_unimplemented && right.is_unimplemented
        }
    | IncompatibleAttributeType left, IncompatibleAttributeType right
      when Type.equal left.parent right.parent &&
           Reference.equal left.incompatible_type.name right.incompatible_type.name ->
        IncompatibleAttributeType {
          parent = left.parent;
          incompatible_type = {
            left.incompatible_type with
            mismatch =
              join_mismatch
                left.incompatible_type.mismatch
                right.incompatible_type.mismatch;
          };
        }
    | IncompatibleVariableType left, IncompatibleVariableType right
      when Reference.equal left.name right.name ->
        IncompatibleVariableType { left with mismatch = join_mismatch left.mismatch right.mismatch }
    | InconsistentOverride ({ override = StrengthenedPrecondition left_issue; _ } as left),
      InconsistentOverride ({ override = StrengthenedPrecondition right_issue; _ } as right) ->
        begin
          match left_issue, right_issue with
          | Found left_mismatch, Found right_mismatch ->
              InconsistentOverride {
                left with
                override =
                  StrengthenedPrecondition (Found (join_mismatch left_mismatch right_mismatch))
              }
          | NotFound _, _ ->
              InconsistentOverride left
          | _, NotFound _ ->
              InconsistentOverride right
        end
    | InconsistentOverride ({ override = WeakenedPostcondition left_mismatch; _ } as left),
      InconsistentOverride { override = WeakenedPostcondition right_mismatch; _ } ->
        InconsistentOverride {
          left with override = WeakenedPostcondition (join_mismatch left_mismatch right_mismatch);
        }
    | InvalidArgument (Keyword left), InvalidArgument (Keyword right)
      when Expression.equal left.expression right.expression ->
        InvalidArgument (
          Keyword {
            left with annotation = Resolution.join resolution left.annotation right.annotation
          })
    | InvalidArgument (Variable left), InvalidArgument (Variable right)
      when Expression.equal left.expression right.expression ->
        InvalidArgument (
          Variable {
            left with annotation = Resolution.join resolution left.annotation right.annotation
          })
    | InvalidMethodSignature left, InvalidMethodSignature right
      when Identifier.equal left.name right.name ->
        InvalidMethodSignature {
          left with
          annotation = (
            Option.merge ~f:(Resolution.join resolution) left.annotation right.annotation
          )
        }
    | InvalidType left, InvalidType right when Type.equal left right ->
        InvalidType left
    | InvalidTypeVariable { annotation = left; origin = left_origin },
      InvalidTypeVariable { annotation = right; origin = right_origin }
      when Type.equal left right && equal_type_variable_origin left_origin right_origin ->
        InvalidTypeVariable { annotation = left; origin = left_origin }
    | InvalidTypeVariance { annotation = left; origin = left_origin },
      InvalidTypeVariance { annotation = right; origin = right_origin }
      when Type.equal left right && equal_type_variance_origin left_origin right_origin ->
        InvalidTypeVariance { annotation = left; origin = left_origin }
    | TooManyArguments left, TooManyArguments right
      when Option.equal Reference.equal_sanitized left.callee right.callee &&
           left.expected = right.expected &&
           left.provided = right.provided ->
        TooManyArguments left
    | UninitializedAttribute left, UninitializedAttribute right
      when String.equal left.name right.name && Type.equal left.parent right.parent ->
        UninitializedAttribute { left with mismatch = join_mismatch left.mismatch right.mismatch }
    | UnawaitedAwaitable left, UnawaitedAwaitable right when Reference.equal_sanitized left right ->
        UnawaitedAwaitable left
    | UndefinedAttribute { origin = Class left; attribute = left_attribute },
      UndefinedAttribute { origin = Class right; attribute = right_attribute }
      when Identifier.equal_sanitized left_attribute right_attribute ->
        let annotation = Resolution.join resolution left.annotation right.annotation in
        UndefinedAttribute { origin = Class { left with annotation }; attribute = left_attribute }

    | UndefinedAttribute { origin = Module left; attribute = left_attribute },
      UndefinedAttribute { origin = Module right; attribute = right_attribute }
      when Identifier.equal_sanitized left_attribute right_attribute &&
           Reference.equal_sanitized left right ->
        UndefinedAttribute { origin = Module left; attribute = left_attribute  }

    | UndefinedName left, UndefinedName right when Reference.equal_sanitized left right ->
        UndefinedName left
    | UndefinedType left, UndefinedType right when Type.equal left right ->
        UndefinedType left
    | UnexpectedKeyword left, UnexpectedKeyword right
      when Option.equal Reference.equal_sanitized left.callee right.callee &&
           Identifier.equal left.name right.name ->
        UnexpectedKeyword left
    | UndefinedImport left, UndefinedImport right when Reference.equal_sanitized left right ->
        UndefinedImport left

    (* Join UndefinedImport/Name pairs into an undefined import, as the missing name is due to us
       being unable to resolve the import. *)
    | UndefinedImport left, UndefinedName right when Reference.equal_sanitized left right ->
        UndefinedImport left
    | UndefinedName left, UndefinedImport right when Reference.equal_sanitized left right ->
        UndefinedImport right

    | UnusedIgnore left, UnusedIgnore right ->
        UnusedIgnore (IntSet.to_list (IntSet.union (IntSet.of_list left) (IntSet.of_list right)))

    | Unpack { expected_count = left_count; unpack_problem = UnacceptableType left },
      Unpack { expected_count = right_count; unpack_problem = UnacceptableType right }
      when left_count = right_count ->
        Unpack {
          expected_count = left_count;
          unpack_problem = UnacceptableType (Resolution.join resolution left right);
        }

    | Unpack { expected_count = left_count; unpack_problem = CountMismatch left },
      Unpack { expected_count = right_count; unpack_problem = CountMismatch right }
      when left_count = right_count && left = right ->
        Unpack { expected_count = left_count; unpack_problem = CountMismatch left }

    | TypedDictionaryKeyNotFound left, TypedDictionaryKeyNotFound right
      when Identifier.equal left.typed_dictionary_name right.typed_dictionary_name &&
           String.equal left.missing_key right.missing_key ->
        TypedDictionaryKeyNotFound left
    | TypedDictionaryAccessWithNonLiteral left, TypedDictionaryAccessWithNonLiteral right
      when List.equal ~equal:String.equal left right ->
        TypedDictionaryAccessWithNonLiteral left
    | Top, _
    | _, Top ->
        Top
    | AnalysisFailure _, _
    | Deobfuscation _, _
    | IllegalAnnotationTarget _, _
    | ImpossibleIsinstance _, _
    | IncompatibleAttributeType _, _
    | IncompatibleAwaitableType _, _
    | IncompatibleConstructorAnnotation _, _
    | IncompatibleParameterType _, _
    | IncompatibleReturnType _, _
    | IncompleteType _, _
    | IncompatibleVariableType _, _
    | InconsistentOverride _, _
    | InvalidArgument _, _
    | InvalidMethodSignature _, _
    | InvalidType _, _
    | InvalidTypeParameters _, _
    | InvalidTypeVariable _, _
    | InvalidTypeVariance _, _
    | MissingArgument _, _
    | MissingAttributeAnnotation _, _
    | MissingGlobalAnnotation _, _
    | MissingParameterAnnotation _, _
    | MissingReturnAnnotation _, _
    | MutuallyRecursiveTypeVariables _, _
    | NotCallable _, _
    | ProhibitedAny _, _
    | RedundantCast _, _
    | RevealedType _, _
    | TooManyArguments _, _
    | TypedDictionaryAccessWithNonLiteral _, _
    | TypedDictionaryKeyNotFound _, _
    | UnawaitedAwaitable _, _
    | UndefinedAttribute _, _
    | UndefinedImport _, _
    | UndefinedName _, _
    | UndefinedType _, _
    | UnexpectedKeyword _, _
    | UninitializedAttribute _, _
    | Unpack _, _
    | UnusedIgnore _, _ ->
        Log.debug
          "Incompatible type in error join at %a: %a %a"
          Location.Instantiated.pp (location left)
          pp_kind left.kind
          pp_kind right.kind;
        Top
  in
  let location =
    if Location.Instantiated.compare left.location right.location <= 0 then
      left.location
    else
      right.location
  in
  { location; kind; signature = left.signature }


let meet ~resolution:_ left _ =
  (* We do not yet care about meeting errors. *)
  left


let widen ~resolution ~previous ~next ~iteration:_ =
  join ~resolution previous next


let join_at_define ~resolution errors =
  let error_map = String.Table.create ~size:(List.length errors) () in
  let add_error errors error =
    let add_error_to_map key =
      let update_error = function
        | None -> error
        | Some existing_error ->
            let joined_error = join ~resolution existing_error error in
            if joined_error.kind <> Top then
              joined_error
            else
              existing_error
      in
      String.Table.update error_map key ~f:update_error;
      errors
    in
    match error with
    | { kind = MissingParameterAnnotation { name; _ }; _ }
    | { kind = MissingReturnAnnotation { name; _ }; _ } ->
        add_error_to_map (Reference.show_sanitized name)
    | _ ->
        error :: errors
  in
  let unjoined_errors = List.fold ~init:[] ~f:add_error errors in
  let joined_errors = String.Table.data error_map in
  (* Preserve the order of the errors as much as possible *)
  List.rev_append unjoined_errors joined_errors


let join_at_source ~resolution errors =
  let key = function
    | { kind = MissingAttributeAnnotation { parent; missing_annotation = { name; _ }; _ }; _ } ->
        Type.show parent ^ Reference.show_sanitized name
    | { kind = MissingGlobalAnnotation { name; _ }; _ } ->
        Reference.show_sanitized name
    | { kind = UndefinedImport name; _ }
    | { kind = UndefinedName name; _ } ->
        Format.asprintf "Unknown[%a]" Reference.pp_sanitized name
    | error ->
        show error
  in
  let add_error errors error =
    let key = key error in
    match Map.find errors key, error.kind with
    | Some { kind = UndefinedImport _; _ }, UndefinedName _ ->
        (* Swallow up UndefinedName errors when the Import error already exists. *)
        errors
    | Some { kind = UndefinedName _; _ }, UndefinedImport _ ->
        Map.set ~key ~data:error errors
    | Some existing_error, _ ->
        let joined_error = join ~resolution existing_error error in
        if not (equal_kind joined_error.kind Top) then
          Map.set ~key ~data:joined_error errors
        else
          errors
    | _ ->
        Map.set ~key ~data:error errors
  in
  List.fold ~init:String.Map.empty ~f:add_error errors
  |> Map.data


let deduplicate errors =
  let error_set = Hash_set.create ~size:(List.length errors) () in
  List.iter errors ~f:(Core.Hash_set.add error_set);
  Core.Hash_set.to_list error_set


let filter ~configuration ~resolution errors =
  let should_filter error =
    let is_mock_error { kind; _ } =
      match kind with
      | IncompatibleAttributeType { incompatible_type = { mismatch = { actual; _ }; _ }; _ }
      | IncompatibleAwaitableType actual
      | IncompatibleParameterType { mismatch = { actual; _ }; _ }
      | IncompatibleReturnType { mismatch = { actual; _ }; _ }
      | IncompatibleVariableType { mismatch = { actual; _ }; _ }
      | UndefinedAttribute { origin = Class { annotation = actual; _ }; _ } ->
          let is_subclass_of_mock annotation =
            try
              (not (Type.equal annotation Type.Bottom)) &&
              ((Resolution.less_or_equal
                  resolution
                  ~left:annotation
                  ~right:(Type.Primitive ("unittest.mock.Base"))) ||
               (* Special-case mypy's workaround for mocks. *)
               (Resolution.less_or_equal
                  resolution
                  ~left:annotation
                  ~right:(Type.Primitive ("unittest.mock.NonCallableMock"))))
            with
            | TypeOrder.Untracked _ ->
                false
          in
          Type.exists actual ~predicate:is_subclass_of_mock
      | UnexpectedKeyword { callee = Some callee; _ } ->
          String.is_prefix ~prefix:"unittest.mock" (Reference.show callee)
      | _ ->
          false
    in
    let is_unimplemented_return_error error =
      match error with
      | { kind = IncompatibleReturnType { is_unimplemented; _ } ; _ } ->
          is_unimplemented
      | _ ->
          false
    in
    let is_builtin_import_error = function
      | { kind = UndefinedImport builtins; _ }
        when String.equal (Reference.show builtins) "builtins" ->
          true
      | _ ->
          false
    in
    let is_stub_error error =
      String.is_suffix ~suffix:".pyi" (path error)
    in
    let is_override_on_dunder_method { kind; _ } =
      (* Ignore naming mismatches on parameters of dunder methods due to unofficial
         typeshed naming *)
      match kind with
      | InconsistentOverride { overridden_method; override; _ }
        when String.is_prefix ~prefix:"__" overridden_method &&
             String.is_suffix ~suffix:"__" overridden_method ->
          begin
            match override with
            | StrengthenedPrecondition (NotFound _) -> true
            | _ -> false
          end
      | _ -> false
    in
    let is_unnecessary_missing_annotation_error { kind; _ } =
      (* Ignore missing annotations thrown at assigns but not thrown where global or attribute was
         originally defined. *)
      match kind with
      | MissingGlobalAnnotation { thrown_at_source; _ }
      | MissingAttributeAnnotation { missing_annotation = { thrown_at_source; _ }; _ } ->
          not thrown_at_source
      | _ ->
          false
    in
    let is_unknown_callable_error { kind; _ } =
      (* TODO(T41494196): Remove when we have AnyCallable escape hatch. *)
      match kind with
      | ImpossibleIsinstance { mismatch = { expected; actual; _ }; _ }
      | InconsistentOverride {
          override = StrengthenedPrecondition (Found { expected; actual; _ });
          _;
        }
      | InconsistentOverride { override = WeakenedPostcondition { expected; actual; _ }; _ }
      | IncompatibleParameterType { mismatch = { expected; actual; _ }; _ }
      | IncompatibleReturnType { mismatch = { expected; actual; _ }; _ }
      | IncompatibleAttributeType {
          incompatible_type = { mismatch = { expected; actual; _ }; _ };
          _;
        }
      | IncompatibleVariableType { mismatch = { expected; actual; _ }; _ } ->
          begin
            match actual with
            | Type.Callable _ ->
                Resolution.less_or_equal
                  resolution
                  ~left:(Type.Callable.create ~annotation:Type.Top ())
                  ~right:expected
            | _ ->
                false
          end
      | _ ->
          false
    in
    let is_special_method_arity_error { kind; _ } =
      let special_method_names =
        (* TODO(T35601774): Remove filter when these are handled properly. *)
        (* https://docs.python.org/3/reference/datamodel.html#special-method-names *)
        [
          "__new__";
          "__init__";
          "__del__";
          "__repr__";
          "__str__";
          "__bytes__";
          "__format__";
          "__lt__";
          "__le__";
          "__eq__";
          "__ne__";
          "__gt__";
          "__ge__";
          "__hash__";
          "__bool__";
          "__call__";
          "__getitem__";
          "__add__";
          "__sub__";
          "__mul__";
          "__matmul__";
          "__truediv__";
          "__floordiv__";
          "__mod__";
          "__divmod__";
          "__pow__";
          "__lshift__";
          "__rshift__";
          "__and__";
          "__xor__";
          "__or__";
        ]
      in
      match kind with
      | MissingArgument { callee = Some access; _ }
      | TooManyArguments { callee = Some access; _ }
      | UnexpectedKeyword { callee = Some access; _ } ->
          begin
            match Reference.prefix access, Reference.last access with
            | None, _ -> false
            | _, name -> List.mem ~equal:String.equal special_method_names name
          end
      | _ ->
          false
    in
    is_stub_error error ||
    is_mock_error error ||
    is_unimplemented_return_error error ||
    is_builtin_import_error error ||
    is_override_on_dunder_method error ||
    is_unnecessary_missing_annotation_error error ||
    is_unknown_callable_error error ||
    is_special_method_arity_error error
  in
  match configuration with
  | { Configuration.Analysis.debug = true; _ } -> errors
  | _ -> List.filter ~f:(fun error -> not (should_filter error)) errors


let suppress ~mode ~resolution error =
  let suppress_in_strict ({ kind; _ } as error) =
    if due_to_analysis_limitations error then
      true
    else
      match kind with
      | UndefinedImport _ ->
          due_to_builtin_import error
      | IncompleteType _ ->
          (* TODO(T42467236): Ungate this when ready to codemod upgrade *)
          true
      | _ ->
          due_to_mismatch_with_any resolution error
  in

  let suppress_in_default
      ~resolution
      ({ kind; signature = { Node.value = signature; _ }; _ } as error) =
    match kind with
    | InconsistentOverride { override = WeakenedPostcondition { actual = Type.Top; _ }; _ } ->
        false
    | InconsistentOverride {
        override = StrengthenedPrecondition (Found { expected = Type.Variable _; _ });
        _;
      } ->
        true
    | InvalidTypeParameters { given_number_of_parameters; _ }
      when given_number_of_parameters = 0 ->
        true
    | IncompleteType _ ->
        (* TODO(T42467236): Ungate this when ready to codemod upgrade *)
        true
    | MissingReturnAnnotation _
    | MissingParameterAnnotation _
    | MissingAttributeAnnotation _
    | MissingGlobalAnnotation _
    | ProhibitedAny _
    | Unpack { unpack_problem = UnacceptableType Type.Any; _ }
    | Unpack { unpack_problem = UnacceptableType Type.Top; _ } ->
        true
    | UndefinedImport _ ->
        false
    | UndefinedName name when String.equal (Reference.show name) "reveal_type" ->
        true
    | RevealedType _ ->
        false
    | _ ->
        due_to_analysis_limitations error ||
        due_to_mismatch_with_any resolution error ||
        (Define.Signature.is_untyped signature && not (Define.Signature.is_toplevel signature))
  in

  let suppress_in_infer { kind; _ } =
    match kind with
    | MissingReturnAnnotation { annotation = Some actual; _ }
    | MissingParameterAnnotation { annotation = Some actual; _ }
    | MissingAttributeAnnotation { missing_annotation = { annotation = Some actual; _ }; _ }
    | MissingGlobalAnnotation { annotation = Some actual; _ } ->
        Type.equal actual Type.Top ||
        Type.equal actual Type.Any ||
        Type.equal actual Type.Bottom
    | _ ->
        true
  in

  if Location.Instantiated.equal (Location.Instantiated.synthetic) (location error) then
    true
  else
    try
      match mode with
      | Source.Infer ->
          suppress_in_infer error
      | Source.Strict ->
          suppress_in_strict error
      | Source.Declare ->
          true
      | Source.DefaultButDontCheck suppressed_codes
        when List.exists suppressed_codes ~f:((=) (code error)) ->
          true
      | _ ->
          suppress_in_default ~resolution error
    with TypeOrder.Untracked annotation ->
      Log.warning "`%s` not found in the type order." (Type.show annotation);
      false

let dequalify
    dequalify_map
    ~resolution
    ({
      kind;
      signature = {
        Node.location;
        value = ({ parameters; return_annotation; _ } as signature)
      }; _ } as error) =
  let dequalify = Type.dequalify dequalify_map in
  let dequalify_mismatch ({ actual; expected; _ } as mismatch) =
    {
      mismatch with
      actual = dequalify actual;
      expected = dequalify expected;
    }
  in
  let kind =
    match kind with
    | AnalysisFailure annotation ->
        AnalysisFailure (dequalify annotation)
    | Deobfuscation left ->
        Deobfuscation left
    | IllegalAnnotationTarget left ->
        IllegalAnnotationTarget left
    | ImpossibleIsinstance ({ mismatch; _ } as isinstance) ->
        ImpossibleIsinstance { isinstance with mismatch = dequalify_mismatch mismatch }
    | IncompatibleAwaitableType actual  ->
        IncompatibleAwaitableType (dequalify actual)
    | IncompatibleConstructorAnnotation annotation ->
        IncompatibleConstructorAnnotation (dequalify annotation)
    | IncompleteType { target; annotation; attempted_action } ->
        IncompleteType { target; annotation = dequalify annotation; attempted_action }
    | InvalidArgument (Keyword { expression; annotation }) ->
        InvalidArgument (Keyword { expression; annotation = dequalify annotation })
    | InvalidArgument (Variable { expression; annotation }) ->
        InvalidArgument (Variable { expression; annotation = dequalify annotation })
    | InvalidMethodSignature ({ annotation; _ } as kind) ->
        InvalidMethodSignature { kind with annotation = (annotation >>| dequalify) }
    | InvalidType annotation ->
        InvalidType (dequalify annotation)
    | InvalidTypeParameters ({ annotation; _ } as missing_type_parameters) ->
        InvalidTypeParameters { missing_type_parameters with annotation = dequalify annotation }
    | InvalidTypeVariable { annotation; origin } ->
        InvalidTypeVariable { annotation = dequalify annotation; origin }
    | InvalidTypeVariance { annotation; origin } ->
        InvalidTypeVariance { annotation = dequalify annotation; origin }
    | TooManyArguments extra_argument ->
        TooManyArguments extra_argument
    | Top ->
        Top
    | MissingParameterAnnotation ({ annotation; _ } as missing_annotation) ->
        MissingParameterAnnotation { missing_annotation with annotation = annotation >>| dequalify }
    | MissingReturnAnnotation ({ annotation; _ } as missing_return) ->
        MissingReturnAnnotation { missing_return with annotation = annotation >>| dequalify; }
    | MissingAttributeAnnotation {
        parent;
        missing_annotation = { annotation; _ } as missing_annotation;
      } ->
        MissingAttributeAnnotation {
          parent;
          missing_annotation = { missing_annotation with annotation = annotation >>| dequalify };
        }
    | MissingGlobalAnnotation ({ annotation; _ } as immutable_type) ->
        MissingGlobalAnnotation {
          immutable_type with  annotation = annotation >>| dequalify;
        }
    | MutuallyRecursiveTypeVariables callee ->
        MutuallyRecursiveTypeVariables callee
    | NotCallable annotation ->
        NotCallable (dequalify annotation)
    | ProhibitedAny ({ annotation; _ } as missing_annotation) ->
        ProhibitedAny { missing_annotation with annotation = annotation >>| dequalify }
    | RedundantCast annotation ->
        RedundantCast (dequalify annotation)
    | RevealedType { expression; annotation } ->
        RevealedType { expression; annotation = dequalify annotation }
    | IncompatibleParameterType ({ mismatch; _; } as parameter) ->
        IncompatibleParameterType { parameter with mismatch = dequalify_mismatch mismatch }
    | IncompatibleReturnType ({ mismatch; _ } as return) ->
        IncompatibleReturnType { return with mismatch = dequalify_mismatch mismatch }
    | IncompatibleAttributeType { parent; incompatible_type = { mismatch; _ } as incompatible_type }
      ->
        IncompatibleAttributeType {
          parent;
          incompatible_type = { incompatible_type with mismatch = dequalify_mismatch mismatch };
        }
    | IncompatibleVariableType ({ mismatch; _ } as incompatible_type) ->
        IncompatibleVariableType { incompatible_type with mismatch = dequalify_mismatch mismatch }
    | InconsistentOverride
        ({ override = StrengthenedPrecondition (Found mismatch); _ } as inconsistent_override) ->
        InconsistentOverride {
          inconsistent_override with
          override = StrengthenedPrecondition (Found (dequalify_mismatch mismatch));
        }
    | InconsistentOverride (
        { override = StrengthenedPrecondition (NotFound access); _ } as inconsistent_override
      ) ->
        InconsistentOverride {
          inconsistent_override with override = StrengthenedPrecondition (NotFound access);
        }
    | InconsistentOverride
        ({ override = WeakenedPostcondition mismatch; _ } as inconsistent_override) ->
        InconsistentOverride {
          inconsistent_override with
          override = WeakenedPostcondition (dequalify_mismatch mismatch);
        }
    | TypedDictionaryAccessWithNonLiteral expression ->
        TypedDictionaryAccessWithNonLiteral expression
    | TypedDictionaryKeyNotFound key ->
        TypedDictionaryKeyNotFound key
    | UninitializedAttribute ({ mismatch; _ } as inconsistent_usage) ->
        UninitializedAttribute {
          inconsistent_usage with
          mismatch = dequalify_mismatch mismatch;
        }
    | UnawaitedAwaitable left ->
        UnawaitedAwaitable left
    | UndefinedAttribute { attribute; origin } ->
        let origin: origin =
          match origin with
          | Class { annotation; class_attribute } ->
              let annotation =
                (* Don't dequalify optionals because we special case their display. *)
                if Type.is_optional_primitive annotation then
                  annotation
                else
                  dequalify annotation
              in
              Class { annotation; class_attribute }
          | _ ->
              origin
        in
        UndefinedAttribute { attribute; origin }
    | UndefinedName access ->
        UndefinedName access
    | UndefinedType annotation ->
        UndefinedType (dequalify annotation)
    | UndefinedImport access ->
        UndefinedImport access
    | UnexpectedKeyword access ->
        UnexpectedKeyword access
    | MissingArgument missing_argument ->
        MissingArgument missing_argument
    | UnusedIgnore codes ->
        UnusedIgnore codes
    | Unpack unpack ->
        Unpack unpack
  in
  let signature =
    let dequalify_parameter ({ Node.value; _ } as parameter) =
      value.Parameter.annotation
      >>| Resolution.parse_annotation ~allow_untracked:true resolution
      >>| dequalify
      >>| Type.expression ~convert:true
      |> fun annotation ->
      { parameter with Node.value = { value with Parameter.annotation }}
    in
    let parameters = List.map parameters ~f:dequalify_parameter in
    let return_annotation =
      return_annotation
      >>| Resolution.parse_annotation ~allow_untracked:true resolution
      >>| dequalify
      >>| Type.expression ~convert:true
    in
    { signature with parameters; return_annotation }
  in
  { error with kind; signature = { Node.location; value = signature} }


let create_mismatch ~resolution ~actual ~actual_expression ~expected ~covariant =
  let left, right =
    if covariant then
      actual, expected
    else
      expected, actual
  in
  {
    expected;
    actual;
    due_to_invariance = Resolution.is_invariance_mismatch resolution ~left ~right;
    actual_expressions = Option.to_list actual_expression;
  }
