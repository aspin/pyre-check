(** Copyright (c) 2018-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Pyre
open Taint

open Interprocedural
open TestHelper


let assert_taint ?(qualifier = "qualifier") source expected =
  let configuration =
    Configuration.Analysis.create
      ~project_root:(Path.current_working_directory ())
      ()
  in

  let source =
    let path = Test.mock_path (qualifier ^ ".py") in
    let file = File.create ~content:(Test.trim_extra_indentation source) path in
    let handle = File.handle file ~configuration in
    Ast.SharedMemory.Sources.remove ~handles:[handle];
    Service.Parser.parse_sources
      ~configuration
      ~scheduler:(Scheduler.mock ())
      ~preprocessing_state:None
      ~files:[file]
    |> ignore;
    match Ast.SharedMemory.Sources.get handle with
    | Some source -> source
    | None -> failwith "Unable to parse source."
  in

  let environment = Test.environment ~configuration () in
  Service.Environment.populate
    ~configuration
    ~scheduler:(Scheduler.mock ())
    environment
    [source];
  TypeCheck.run ~configuration ~environment ~source |> ignore;
  let defines =
    source
    |> Preprocessing.convert
    |> Preprocessing.defines ~include_stubs:true
    |> List.rev
  in
  let () =
    List.map ~f:Callable.create defines
    |> Fixpoint.KeySet.of_list
    |> Fixpoint.remove_new
  in
  let analyze_and_store_in_order define =
    let call_target = Callable.create define in
    let () =
      Log.log
        ~section:`Taint
        "Analyzing %a"
        Interprocedural.Callable.pp
        call_target
    in
    let backward =
      BackwardAnalysis.run
        ~environment
        ~define
        ~existing_model:Taint.Result.empty_model
    in
    let model = { Taint.Result.empty_model with backward } in
    Result.empty_model
    |> Result.with_model Taint.Result.kind model
    |> Fixpoint.add_predefined Fixpoint.Epoch.predefined call_target
  in
  let () = List.iter ~f:analyze_and_store_in_order defines in
  List.iter ~f:check_expectation expected


let test_plus_taint_in_taint_out _ =
  assert_taint
    {|
    def test_plus_taint_in_taint_out(tainted_parameter1, parameter2):
      tainted_value = tainted_parameter1 + 5
      return tainted_value
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["tainted_parameter1"]
        "qualifier.test_plus_taint_in_taint_out";
    ]


let test_concatenate_taint_in_taint_out _ =
  assert_taint
    {|
      def test_concatenate_taint_in_taint_out(parameter0, tainted_parameter1):
        unused_parameter = parameter0
        command_unsafe = 'echo' + tainted_parameter1 + ' >> /dev/null'
        return command_unsafe
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["tainted_parameter1"]
        "qualifier.test_concatenate_taint_in_taint_out";
    ]


let test_call_taint_in_taint_out _ =
  assert_taint
    {|
      def test_base_tito(parameter0, tainted_parameter1):
        return tainted_parameter1

      def test_called_tito(tainted_parameter0, parameter1):
        return test_base_tito(parameter1, tainted_parameter0)
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["tainted_parameter1"]
        "qualifier.test_base_tito";
      outcome
        ~kind:`Function
        ~tito_parameters:["tainted_parameter0"]
        "qualifier.test_called_tito";
    ]


let test_sink _ =
  assert_taint
    {|
      def test_sink(parameter0, tainted_parameter1):
        unused_parameter = parameter0
        command_unsafe = 'echo' + tainted_parameter1 + ' >> /dev/null'
        __test_sink(command_unsafe)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          {
            name = "tainted_parameter1";
            sinks = [Taint.Sinks.Test];
          };
        ]
        "qualifier.test_sink";
    ]


let test_rce_sink _ =
  assert_taint
    {|
      def test_rce_sink(parameter0, tainted_parameter1):
        unused_parameter = parameter0
        command_unsafe = 'echo' + tainted_parameter1 + ' >> /dev/null'
        eval(command_unsafe)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          {
            name = "tainted_parameter1";
            sinks = [Taint.Sinks.RemoteCodeExecution];
          }
        ]
        "qualifier.test_rce_sink";
    ]


let test_hardcoded_rce_sink _ =
  assert_taint
    {|
      def test_hardcoded_rce_sink(input):
        subprocess.call(input, shell=True)

      def test_hardcoded_rce_sink_with_shell_false_explicit(input):
        subprocess.call(input, shell=False)

      def test_hardcoded_rce_sink_with_shell_false_implicit(input):
        subprocess.call(input, shell=False)

      def test_hardcoded_rce_sink_with_string_argument(input: str):
        subprocess.check_call(input, shell=True)

      def test_hardcoded_rce_sink_with_list_literal():
        subprocess.call([], shell=True)

      def test_hardcoded_rce_sink_with_list_argument(input: typing.List[str]):
        subprocess.call(input, shell=True)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "input"; sinks = [Taint.Sinks.RemoteCodeExecution] }]
        "qualifier.test_hardcoded_rce_sink";
      outcome
        ~kind:`Function
        "qualifier.test_hardcoded_rce_sink_with_shell_false_explicit";
      outcome
        ~kind:`Function
        "qualifier.test_hardcoded_rce_sink_with_shell_false_implicit";
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "input"; sinks = [Taint.Sinks.RemoteCodeExecution] }]
        "qualifier.test_hardcoded_rce_sink_with_string_argument";
      outcome
        ~kind:`Function
        "qualifier.test_hardcoded_rce_sink_with_list_literal";
      outcome
        ~kind:`Function
        "qualifier.test_hardcoded_rce_sink_with_list_argument";
    ]


let test_rce_and_test_sink _ =
  assert_taint
    {|
      def test_rce_and_test_sink(test_only, rce_only, both):
        __test_sink(test_only)
        eval(rce_only)
        if True:
          __test_sink(both)
        else:
          eval(both)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "test_only"; sinks = [Taint.Sinks.Test]; };
          { name = "rce_only"; sinks = [Taint.Sinks.RemoteCodeExecution]; };
          { name = "both"; sinks = [Taint.Sinks.RemoteCodeExecution; Taint.Sinks.Test]; };
        ]
        "qualifier.test_rce_and_test_sink";
    ]


let test_tito_sink _ =
  assert_taint
    {|
      def test_base_tito(parameter0, tainted_parameter1):
        return tainted_parameter1

      def test_called_tito(tainted_parameter0, parameter1):
        return test_base_tito(parameter1, tainted_parameter0)

      def test_tito_sink(parameter0, tainted_parameter1):
        tainted = test_called_tito(tainted_parameter1, parameter0)
        __test_sink(tainted)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "tainted_parameter1"; sinks = [Taint.Sinks.Test]; };
        ]
        "qualifier.test_tito_sink";
    ]


let test_apply_method_model_at_call_site _ =
  assert_taint
    {|
      class Foo:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      def taint_across_methods(tainted_parameter):
        f = Foo()
        return f.qux(tainted_parameter)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "tainted_parameter"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.taint_across_methods";
    ];

  assert_taint
    {|
      class Foo:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      def taint_across_methods(not_tainted_parameter):
        f = Bar()
        return f.qux(not_tainted_parameter)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        "qualifier.taint_across_methods";
    ];

  assert_taint
    {|
      class Foo:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      def taint_across_methods(f: Foo, tainted_parameter):
        return f.qux(tainted_parameter)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "tainted_parameter"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.taint_across_methods";
    ];

  assert_taint
    {|
      class Foo:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      def taint_across_methods(f: Bar, not_tainted_parameter):
        return f.qux(not_tainted_parameter)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        "qualifier.taint_across_methods";
    ] ;

  assert_taint
    {|
      class Foo:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      def taint_across_union_receiver_types(condition, tainted_parameter):
        if condition:
          f = Foo()
        else:
          f = Bar()

        return f.qux(tainted_parameter)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "tainted_parameter"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.taint_across_union_receiver_types";
    ];

  assert_taint
    {|
      class Foo:
        def qux(self, not_tainted_parameter):
          pass

      class Bar:
        def qux(self, not_tainted_parameter):
          pass

      class Baz:
        def qux(self, tainted_parameter):
          command_unsafe = tainted_parameter
          __test_sink(command_unsafe)

      def taint_across_union_receiver_types(condition, tainted_parameter):
        if condition:
          f = Foo()
        elif condition > 1:
          f = Bar()
        else:
          f = Baz()

        return f.qux(tainted_parameter)
    |}
    [
      outcome
        ~kind:`Method
        ~sink_parameters:[]
        "qualifier.Foo.qux";
      outcome
        ~kind:`Method
        ~sink_parameters:[
          { name = "tainted_parameter"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.Baz.qux";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "tainted_parameter"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.taint_across_union_receiver_types";
    ];

  (* Propagation through properties. *)
  assert_taint
    {|
      class Class:
        self.tainted = ...
        @property
        def property(self):
          return self.tainted

      c: Class = ...

      def property_into_sink(input):
        c.tainted = input
        __test_sink(c.property)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "input"; sinks = [Taint.Sinks.Test] }]
        "qualifier.property_into_sink";
    ]


let test_tito_via_receiver _ =
  assert_taint
    {|
      class Foo:
        def tito(self, argument1):
            return self.f

      def tito_via_receiver(parameter):
        x = Foo()
        x.f = parameter
        return f.tito
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["parameter"]
        "qualifier.tito_via_receiver";
      outcome
        ~kind:`Function
        ~tito_parameters:["self"]
        "qualifier.Foo.tito";
    ]


let test_sequential_call_path _ =
  (* Testing the setup to get this out of the way. *)
  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self
    |}
    [
      outcome
        ~kind:`Method
        ~sink_parameters:[
          { name = "argument"; sinks = [Taint.Sinks.Test] };
        ]
        ~tito_parameters:["self"]
        "qualifier.Foo.sink";
    ];

  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self

      def sequential_with_single_sink(first, second, third):
        x = Foo()
        x.sink(first)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "first"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sequential_with_single_sink";
    ];
  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self

      def sequential_with_two_sinks(first, second, third):
        x = Foo()
        x.sink(first)
        x.sink(second)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "first"; sinks = [Taint.Sinks.Test] };
          { name = "second"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sequential_with_two_sinks";
    ];
  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self

      def sequential_with_redefine(first, second, third):
        x = Foo()
        x.sink(first)
        x = Foo()
        x.sink(second)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "first"; sinks = [Taint.Sinks.Test] };
          { name = "second"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sequential_with_redefine";
    ];
  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self

      def sequential_with_distinct_sinks(first, second, third):
        x = Foo()
        x.sink(first)
        a = Foo()
        a.sink(second)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "first"; sinks = [Taint.Sinks.Test] };
          { name = "second"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sequential_with_distinct_sinks";
    ];
  assert_taint
    {|
      class Foo:
        def sink(self, argument) -> Foo:
            __test_sink(argument)
            return self

      def sequential_with_self_propagation(first, second, third):
        x = Foo()
        x = x.sink(first)
        x.sink(second)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "first"; sinks = [Taint.Sinks.Test] };
          { name = "second"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sequential_with_self_propagation";
    ]


let test_chained_call_path _ =
  assert_taint
    {|
      class Foo:
        def sink(self, argument1) -> Foo:
            __test_sink(argument1)
            return self

      def chained(parameter0, parameter1, parameter2):
        x = Foo()
        x.sink(parameter0).sink(parameter2)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter0"; sinks = [Taint.Sinks.Test] };
          { name = "parameter2"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.chained";
    ];
  assert_taint
    {|
      class Foo:
        def tito(self, argument1) -> Foo:
            return self

        def sink(self, argument1) -> Foo:
            __test_sink(argument1)
            return self

      def chained_with_tito(parameter0, parameter1, parameter2):
        x = Foo()
        x.sink(parameter0).tito(parameter1).sink(parameter2)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter0"; sinks = [Taint.Sinks.Test] };
          { name = "parameter2"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.chained_with_tito";
    ]


let test_dictionary _ =
  assert_taint
    {|
      def dictionary_sink(arg):
        {
          "a": __test_sink(arg),
        }

      def dictionary_tito(arg):
        return {
          "a": arg,
        }

      def dictionary_same_index(arg):
        dict = {
          "a": arg,
        }
        return dict["a"]

      def dictionary_different_index(arg):
        dict = {
          "a": arg,
        }
        return dict["b"]

      def dictionary_unknown_read_index(arg, index):
        dict = {
          "a": arg,
        }
        return dict[index]

      def dictionary_unknown_write_index(arg, index):
        dict = {
          index: arg,
        }
        return dict["a"]
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.dictionary_sink";
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        ~tito_parameters:["arg"]
        "qualifier.dictionary_tito";
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        ~tito_parameters:["arg"]
        "qualifier.dictionary_same_index";
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        ~tito_parameters:[]
        "qualifier.dictionary_different_index";
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        ~tito_parameters:["arg"]
        "qualifier.dictionary_unknown_read_index";
      outcome
        ~kind:`Function
        ~sink_parameters:[]
        ~tito_parameters:["arg"]
        "qualifier.dictionary_unknown_write_index";
    ]


let test_comprehensions _ =
  assert_taint
    {|
      def sink_in_iterator(arg):
          [ x for x in __test_sink(arg) ]

      def sink_in_expression(data):
          [ __test_sink(x) for x in data ]

      def tito(data):
          return [x for x in data ]

      def sink_in_set_iterator(arg):
          { x for x in __test_sink(arg) }

      def sink_in_set_expression(data):
          { __test_sink(x) for x in data }

      def tito_set(data):
          return { x for x in data }

      def sink_in_generator_iterator(arg):
          gen = (x for x in __test_sink(arg))

      def sink_in_generator_expression(data):
          gen = (__test_sink(x) for x in data)

      def tito_generator(data):
          return (x for x in data)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_iterator";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "data"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_expression";
      outcome
        ~kind:`Function
        ~tito_parameters:["data"]
        "qualifier.tito";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_set_iterator";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "data"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_set_expression";
      outcome
        ~kind:`Function
        ~tito_parameters:["data"]
        "qualifier.tito_set";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_generator_iterator";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "data"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_generator_expression";
      outcome
        ~kind:`Function
        ~tito_parameters:["data"]
        "qualifier.tito_generator";
    ]


let test_list _ =
  assert_taint
    {|
      def sink_in_list(arg):
          return [ 1, __test_sink(arg), "foo" ]

      def list_same_index(arg):
          list = [ 1, arg, "foo" ]
          return list[1]

      def list_different_index(arg):
          list = [ 1, arg, "foo" ]
          return list[2]

      def list_unknown_index(arg, index):
          list = [ 1, arg, "foo" ]
          return list[index]

      def list_pattern_same_index(arg):
          [_, result, _] = [ 1, arg, "foo" ]
          return result

      def list_pattern_different_index(arg):
          [_, _, result] = [ 1, arg, "foo" ]
          return result

      def list_pattern_star_index(arg):
          [_, _, *result] = [ 1, arg, "foo" ]
          return result
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_list";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.list_same_index";
      outcome
        ~kind:`Function
        "qualifier.list_different_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.list_unknown_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.list_pattern_same_index";
      outcome
        ~kind:`Function
        "qualifier.list_pattern_different_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.list_pattern_star_index";
    ]


let test_tuple _ =
  assert_taint
    {|
      def sink_in_tuple(arg):
          return ( 1, __test_sink(arg), "foo" )

      def tuple_same_index(arg):
          tuple = ( 1, arg, "foo" )
          return tuple[1]

      def tuple_different_index(arg):
          tuple = ( 1, arg, "foo" )
          return tuple[2]

      def tuple_unknown_index(arg, index):
          tuple = ( 1, arg, "foo" )
          return tuple[index]

      def tuple_pattern_same_index(arg):
          (_, result, _) = ( 1, arg, "foo" )
          return result

      def tuple_pattern_different_index(arg):
          (_, _, result) = ( 1, arg, "foo" )
          return result
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_tuple";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tuple_same_index";
      outcome
        ~kind:`Function
        "qualifier.tuple_different_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tuple_unknown_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tuple_pattern_same_index";
      outcome
        ~kind:`Function
        "qualifier.tuple_pattern_different_index";
    ]


let test_lambda _ =
  assert_taint
    {|
      def sink_in_lambda(arg):
          f = lambda x : x + __test_sink(arg)

      def lambda_tito(arg):
          f = lambda x : x + arg
          return f
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_lambda";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.lambda_tito";
    ]


let test_set _ =
  assert_taint
    {|
      def sink_in_set(arg):
          return { 1, __test_sink(arg), "foo" }

      def set_index(arg):
          set = { 1, arg, "foo" }
          return set[2]

      def set_unknown_index(arg, index):
          set = { 1, arg, "foo" }
          return set[index]
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_set";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.set_index";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.set_unknown_index";
    ]


let test_starred _ =
  assert_taint
    {|
      def sink_in_starred(arg):
          __tito( *[ 1, __test_sink(arg), "foo" ] )

      def sink_in_starred_starred(arg):
          __tito( **{
              "a": 1,
              "b": __test_sink(arg),
              "c": "foo",
          })

      def tito_in_starred(arg):
          return __tito( *[ 1, arg, "foo" ] )

      def tito_in_starred_starred(arg):
          return __tito( **{
              "a": 1,
              "b": arg,
              "c": "foo",
          })
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_starred";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_starred_starred";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_in_starred";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_in_starred_starred";
    ]


let test_ternary _ =
  assert_taint
    {|
      def sink_in_then(arg, cond):
          x = __test_sink(arg) if cond else None

      def sink_in_else(arg, cond):
          x = "foo" if cond else __test_sink(arg)

      def sink_in_both(arg1, arg2, cond):
          x = __test_sink(arg1) if cond else __test_sink(arg2)

      def sink_in_cond(arg1, arg2, cond):
          x = arg1 if __test_sink(cond) else arg2

      def tito_in_then(arg, cond):
          return arg if cond else None

      def tito_in_else(arg, cond):
          return "foo" if cond else arg

      def tito_in_both(arg1, arg2, cond):
          return arg1 if cond else arg2
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_then";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_else";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg1"; sinks = [Taint.Sinks.Test] };
          { name = "arg2"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_both";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "cond"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_cond";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_in_then";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_in_else";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg1"; "arg2"]
        "qualifier.tito_in_both";
    ]


let test_unary _ =
  assert_taint
    {|
      def sink_in_unary(arg):
          x = not __test_sink(arg)

      def tito_via_unary(arg):
          return not arg
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_unary";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_via_unary";
    ]


let test_yield _ =
  assert_taint
    {|
      def sink_in_yield(arg):
          yield __test_sink(arg)

      def tito_via_yield(arg):
          yield arg

      def sink_in_yield_from(arg):
          yield from __test_sink(arg)

      def tito_via_yield_from(arg):
          yield from arg
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_yield";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_via_yield";
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "arg"; sinks = [Taint.Sinks.Test] };
        ]
        "qualifier.sink_in_yield_from";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.tito_via_yield_from";
    ]


let test_named_arguments _ =
  assert_taint
    {|
      def with_kw(a, b, **kw):
          return kw

      def no_kw_tito(arg0, arg1, arg2, arg3):
          return with_kw(arg0, arg1, arg2, arg3)

      def no_kw_tito_with_named_args(arg0, arg1):
          return with_kw(b = arg0, a = arg1, c = 5)

      def kw_tito_with_named_args(arg0, arg1):
          return with_kw(b = arg0, c = arg1)

      def kw_tito_with_dict(arg0, dict):
          return with_kw(b = arg0, c = 5, **dict)
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["**"]
        "qualifier.with_kw";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.no_kw_tito";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.no_kw_tito_with_named_args";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg1"]
        "qualifier.kw_tito_with_named_args";
      outcome
        ~kind:`Function
        ~tito_parameters:["dict"]
        "qualifier.kw_tito_with_dict";
    ]


let test_actual_parameter_matching _ =
  assert_taint
    {|
      def before_star(a, b, *rest, c, d, **kw):
          return b

      def at_star(a, b, *rest, c, d, **kw):
          return rest[0]

      def at_star_plus_one(a, b, *rest, c, d, **kw):
          return rest[1]

      def at_all_star(a, b, *rest, c, d, **kw):
          return rest[x]

      def after_star(a, b, *rest, c, d, **kw):
          return c

      def star_star_q(a, b, *rest, c, d, **kw):
          return kw['q']

      def star_star_all(a, b, *rest, c, d, **kw):
          return kw[x]

      def pass_positional_before_star(arg, no_tito):
          return before_star(
            no_tito,
            arg,
            no_tito,
            *no_tito,
            no_tito,
            c = no_tito,
            q = no_tito,
            r = no_tito,
            **no_tito,
          )

      def pass_positional_at_star(arg, approximate, no_tito):
          return at_star(
            no_tito,
            no_tito,
            arg,
            no_tito,
            *approximate,
            c = no_tito,
            q = no_tito,
            r = no_tito,
            **no_tito,
          )

      def pass_positional_at_star_plus_one(arg, approximate, no_tito):
          return at_star_plus_one(
            no_tito,
            no_tito,
            no_tito,
            arg,
            no_tito,
            *approximate,
            c = no_tito,
            q = no_tito,
            r = no_tito,
            **no_tito,
          )

      def pass_positional_at_all_star(arg, approximate, no_tito):
          return at_all_star(
            no_tito,
            no_tito,
            2,
            arg,
            3,
            *approximate,
            c = no_tito,
            q = no_tito,
            r = no_tito,
            **no_tito,
          )

      def pass_named_after_star(arg, approximate, no_tito):
          return after_star(
            no_tito,
            no_tito,
            no_tito,
            *no_tito,
            no_tito,
            *no_tito,
            c = arg,
            d = no_tito,
            q = no_tito,
            r = no_tito,
            **approximate,
          )

      def pass_named_as_positional(arg, no_tito):
          return before_star(
            no_tito,
            0,
            *no_tito,
            a = no_tito,
            b = arg,
            c = no_tito,
            q = no_tito,
            **no_tito,
          )

      def pass_named_as_star_star_q(arg, approximate_one, approximate_two, no_tito):
          return star_star_q(
            no_tito,
            no_tito,
            no_tito,
            *no_tito,
            no_tito,
            *no_tito,
            no_tito,
            c = no_tito,
            d = no_tito,
            q = arg,
            r = no_tito,
            **approximate_one,
            **approximate_two,
          )

      def pass_named_as_star_star_all(arg, approximate_one, approximate_two, no_tito):
          return star_star_all(
            no_tito,
            no_tito,
            no_tito,
            *no_tito,
            no_tito,
            *no_tito,
            no_tito,
            c = no_tito,
            d = no_tito,
            r = arg,
            **approximate_one,
            **approximate_two,
          )

      def pass_list_before_star(listarg, arg, no_tito):
          return before_star(
            no_tito,
            *listarg,
            arg,
            no_tito,
            *no_tito,
            no_tito,
            c = no_tito,
            d = no_tito,
            q = no_tito,
            r = no_tito,
          )

      def pass_list_at_star(listarg_one, listarg_two, approximate, no_tito):
          return at_star(
            no_tito,
            *listarg_one,
            approximate,
            *listarg_two,
            c = no_tito,
            d = no_tito,
            q = no_tito,
            r = no_tito,
          )
    |}
    [
      outcome
        ~kind:`Function
        ~tito_parameters:["b"]
        "qualifier.before_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["*"]
        "qualifier.at_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["c"]
        "qualifier.after_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["**"]
        "qualifier.star_star_q";
      outcome
        ~kind:`Function
        ~tito_parameters:["**"]
        "qualifier.star_star_all";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.pass_positional_before_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate"; "arg"]
        "qualifier.pass_positional_at_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate"; "arg"]
        "qualifier.pass_positional_at_star_plus_one";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate"; "arg"]
        "qualifier.pass_positional_at_all_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate"; "arg"]
        "qualifier.pass_named_after_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"]
        "qualifier.pass_named_as_positional";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate_one"; "approximate_two"; "arg"]
        "qualifier.pass_named_as_star_star_q";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate_one"; "approximate_two"; "arg"]
        "qualifier.pass_named_as_star_star_all";
      outcome
        ~kind:`Function
        ~tito_parameters:["arg"; "listarg"]
        "qualifier.pass_list_before_star";
      outcome
        ~kind:`Function
        ~tito_parameters:["approximate"; "listarg_one"; "listarg_two"]
        "qualifier.pass_list_at_star";
    ]


let test_constructor_argument_tito _ =
  assert_taint
    {|
      class Data:
        def __init__(self, tito, no_tito):
          self.field = tito

      def tito_via_construction(tito, no_tito):
          x = Data(tito, no_tito)
          return x

      def no_tito_via_construction(tito, no_tito):
          x = Data(tito, no_tito)
          return x.no_tito

      def precise_tito_via_construction(tito, no_tito):
          x = Data(tito, no_tito)
          return x.field

      def deep_tito_via_assignments(tito, no_tito):
          x = {}
          x.f = tito
          y = {}
          y.g = x
          return y

      def apply_deep_tito_some(tito, no_tito):
          x = deep_tito_via_assignments(tito, no_tito)
          return x.g.f

      def apply_deep_tito_none(tito, no_tito):
          x = deep_tito_via_assignments(tito, no_tito)
          return x.f.g

      def deep_tito_via_objects(tito, no_tito):
          x = { 'f': tito }
          y = { 'g': x }
          return y

      def apply_deep_tito_via_objects_some(tito, no_tito):
          x = deep_tito_via_objects(tito, no_tito)
          return x.g.f

      def apply_deep_tito_via_objects_none(tito, no_tito):
          x = deep_tito_via_objects(tito, no_tito)
          return x.f.g

      def deep_tito_wrapper(tito, no_tito):
          return deep_tito_via_assignments(tito, no_tito)

      def deep_tito_via_multiple(tito, no_tito):
          x = { 'f': tito, 'h': tito }
          y = { 'g': x }
          return y

      def test_tito_via_multiple_some(tito, no_tito):
          x = deep_tito_via_multiple(tito, no_tito)
          return x.g.f

      def test_tito_via_multiple_some_more(tito, no_tito):
          x = deep_tito_via_multiple(tito, no_tito)
          return x.g.h

      def test_tito_via_multiple_none(tito, no_tito):
          x = deep_tito_via_multiple(tito, no_tito)
          return x.g.q
    |}
    [
      outcome
        ~kind:`Method
        ~tito_parameters:["self"; "tito"]
        "qualifier.Data.__init__";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.tito_via_construction";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.no_tito_via_construction";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.precise_tito_via_construction";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.deep_tito_via_assignments";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.apply_deep_tito_some";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.apply_deep_tito_none";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.deep_tito_via_objects";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.apply_deep_tito_via_objects_some";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.apply_deep_tito_via_objects_none";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.deep_tito_wrapper";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.deep_tito_via_multiple";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.test_tito_via_multiple_some";
      outcome
        ~kind:`Function
        ~tito_parameters:["tito"]
        "qualifier.test_tito_via_multiple_some_more";
      outcome
        ~kind:`Function
        ~tito_parameters:[]
        "qualifier.test_tito_via_multiple_none";
    ]


let test_decorator _ =
  assert_taint
    {|
      @$strip_first_parameter
      def decorated(self, into_sink):
        __test_sink(into_sink)

      def using_decorated(into_decorated):
        decorated(into_decorated)
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "into_sink"; sinks = [Taint.Sinks.Test] }]
        "qualifier.decorated";
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "into_decorated"; sinks = [Taint.Sinks.Test] }]
        "qualifier.using_decorated";
    ]


let test_assignment _ =
  assert_taint
    {|
      def assigns_to_sink(assigned_to_sink):
        taint.__global_sink = assigned_to_sink
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "assigned_to_sink"; sinks = [Taint.Sinks.Test] }]
        "qualifier.assigns_to_sink";
    ];
  assert_taint
    {|
      def assigns_to_sink(assigned_to_sink):
        sink = ClassWithSinkAttribute()
        sink.attribute = assigned_to_sink
    |}
    [
      outcome
        ~kind:`Function
        ~sink_parameters:[{ name = "assigned_to_sink"; sinks = [Taint.Sinks.Test] }]
        "qualifier.assigns_to_sink";
    ]


let () =
  "taint">:::[
    "plus_taint_in_taint_out">::test_plus_taint_in_taint_out;
    "concatenate_taint_in_taint_out">::test_concatenate_taint_in_taint_out;
    "rce_sink">::test_rce_sink;
    "hardcoded_rce_sink">::test_hardcoded_rce_sink;
    "test_sink">::test_sink;
    "rce_and_test_sink">::test_rce_and_test_sink;
    "test_call_tito">::test_call_taint_in_taint_out;
    "test_tito_sink">::test_tito_sink;
    "test_apply_method_model_at_call_site">::test_apply_method_model_at_call_site;
    "test_seqential_call_path">::test_sequential_call_path;
    "test_chained_call_path">::test_chained_call_path;
    "test_dictionary">::test_dictionary;
    "test_comprehensions">::test_comprehensions;
    "test_list">::test_list;
    "test_lambda">::test_lambda;
    "test_set">::test_set;
    "test_starred">::test_starred;
    "test_ternary">::test_ternary;
    "test_tuple">::test_tuple;
    "test_unary">::test_unary;
    "test_yield">::test_yield;
    "test_named_arguments">::test_named_arguments;
    "test_actual_parameter_matching">::test_actual_parameter_matching;
    "test_constructor_argument_tito">::test_constructor_argument_tito;
    "decorator">::test_decorator;
    "assignment">::test_assignment;
  ]
  |> TestHelper.run_with_taint_models
