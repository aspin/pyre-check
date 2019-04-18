(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open OUnit2

open Core

open Server
open Protocol
open Pyre
open Test


let test_parse_query context =
  let configuration = Configuration.Analysis.create ~local_root:(mock_path "") () in
  let assert_parses serialized query =
    assert_equal
      ~cmp:Request.equal
      ~printer:Request.show
      (Request.TypeQueryRequest query)
      (Query.parse_query ~configuration serialized)
  in

  let assert_fails_to_parse serialized =
    try
      Query.parse_query ~configuration serialized
      |> ignore;
      assert_unreached ()
    with Query.InvalidQuery _ ->
      ()
  in

  assert_parses
    "less_or_equal(int, bool)"
    (LessOrEqual (!+"int", !+"bool"));
  assert_parses
    "less_or_equal (int, bool)"
    (LessOrEqual (!+"int", !+"bool"));
  assert_parses
    "less_or_equal(  int, int)"
    (LessOrEqual (!+"int", !+"int"));
  assert_parses
    "Less_Or_Equal(  int, int)"
    (LessOrEqual (!+"int", !+"int"));

  assert_parses
    "is_compatible_with(int, bool)"
    (IsCompatibleWith (!+"int", !+"bool"));
  assert_parses
    "is_compatible_with (int, bool)"
    (IsCompatibleWith (!+"int", !+"bool"));
  assert_parses
    "is_compatible_with(  int, int)"
    (IsCompatibleWith (!+"int", !+"int"));
  assert_parses
    "Is_Compatible_With(  int, int)"
    (IsCompatibleWith (!+"int", !+"int"));

  assert_parses
    "meet(int, bool)"
    (Meet (!+"int", !+"bool"));
  assert_parses
    "join(int, bool)"
    (Join (!+"int", !+"bool"));

  assert_fails_to_parse "less_or_equal()";
  assert_fails_to_parse "less_or_equal(int, int, int)";
  assert_fails_to_parse "less_or_eq(int, bool)";

  assert_fails_to_parse "is_compatible_with()";
  assert_fails_to_parse "is_compatible_with(int, int, int)";
  assert_fails_to_parse "iscompatible(int, bool)";
  assert_fails_to_parse "IsCompatibleWith(int, bool)";

  assert_fails_to_parse "meet(int, int, int)";
  assert_fails_to_parse "meet(int)";

  assert_fails_to_parse "join(int)";
  assert_parses "superclasses(int)" (Superclasses (!+"int"));
  assert_fails_to_parse "superclasses()";
  assert_fails_to_parse "superclasses(int, bool)";

  assert_parses "normalize_type(int)" (NormalizeType (!+"int"));
  assert_fails_to_parse "normalizeType(int, str)";

  assert_equal
    (Query.parse_query ~configuration "type_check('derp/fiddle.py')")
    (Request.TypeCheckRequest
       [File.create (Path.create_relative ~root:(mock_path "") ~relative:"derp/fiddle.py")]);

  assert_parses "type(C)" (Type (!"C"));
  assert_parses "type((C,B))" (Type (+(Ast.Expression.Tuple [!"C"; !"B"])));
  assert_fails_to_parse "type(a.b, c.d)";

  assert_fails_to_parse "typecheck(1+2)";

  assert_parses
    "type_at_position('a.py', 1, 2)"
    (TypeAtPosition {
        file = File.create (Path.create_relative ~root:(mock_path "") ~relative:"a.py");
        position = { Ast.Location.line = 1; column = 2 };
      });
  assert_fails_to_parse "type_at_position(a.py:1:2)";
  assert_fails_to_parse "type_at_position('a.py', 1, 2, 3)";

  assert_parses
    "types_in_file('a.py')"
    (TypesInFile (File.create (Path.create_relative ~root:(mock_path "") ~relative:"a.py")));
  assert_fails_to_parse "types_in_file(a.py:1:2)";
  assert_fails_to_parse "types_in_file(a.py)";
  assert_fails_to_parse "types_in_file('a.py', 1, 2)";

  assert_parses
    "coverage_in_file('a.py')"
    (CoverageInFile (File.create (Path.create_relative ~root:(mock_path "") ~relative:"a.py")));
  assert_fails_to_parse "coverage_in_file(a.py:1:2)";
  assert_fails_to_parse "coverage_in_file(a.py)";
  assert_fails_to_parse "coverage_in_file('a.py', 1, 2)";

  assert_parses "attributes(C)" (Attributes (!&"C"));
  assert_fails_to_parse "attributes(C, D)";

  assert_parses "signature(a.b)" (Signature (!&"a.b"));
  assert_fails_to_parse "signature(a.b, a.c)";

  assert_parses "save_server_state('state')"
    (SaveServerState
       (Path.create_absolute
          ~follow_symbolic_links:false
          "state"));
  assert_fails_to_parse "save_server_state(state)";

  assert_parses "dump_dependencies('quoted.py')"
    (DumpDependencies
       (File.create (Path.create_relative ~root:(mock_path "") ~relative:"quoted.py")));
  assert_fails_to_parse "dump_dependencies(unquoted)";

  assert_parses
    "dump_memory_to_sqlite()"
    (DumpMemoryToSqlite
       (Path.create_relative ~root:(mock_path "") ~relative:".pyre/memory.sqlite"));
  let memory_file, _ = bracket_tmpfile context in
  assert_parses
    (Format.sprintf "dump_memory_to_sqlite('%s')" memory_file)
    (DumpMemoryToSqlite (Path.create_absolute memory_file));
  assert_parses
    (Format.sprintf "dump_memory_to_sqlite('a.sqlite')")
    (DumpMemoryToSqlite
       (Path.create_relative
          ~root:(Path.current_working_directory ())
          ~relative:"a.sqlite"));
  assert_parses
    (Format.sprintf "dump_memory_to_sqlite('%s/%s')"
       (Path.absolute (Path.current_working_directory ()))
       "absolute.sqlite")
    (DumpMemoryToSqlite
       (Path.create_relative
          ~root:(Path.current_working_directory ())
          ~relative:"absolute.sqlite"));
  assert_parses "path_of_module(a.b.c)" (PathOfModule (!&"a.b.c"));
  assert_fails_to_parse "path_of_module('a.b.c')";
  assert_fails_to_parse "path_of_module(a.b, b.c)";

  assert_parses "compute_hashes_to_keys()" ComputeHashesToKeys;
  assert_fails_to_parse "compute_hashes_to_keys(foo)";
  assert_parses "decode_ocaml_values()" (DecodeOcamlValues []);
  assert_parses
    "decode_ocaml_values(('first_key', 'first_value'))"
    (DecodeOcamlValues [{
         TypeQuery.serialized_key = "first_key";
         serialized_value = "first_value";
       }]);
  assert_parses
    "decode_ocaml_values(('first_key', 'first_value'), ('second_key', 'second_value'))"
    (DecodeOcamlValues [
        {
          TypeQuery.serialized_key = "first_key";
          serialized_value = "first_value";
        };
        {
          TypeQuery.serialized_key = "second_key";
          serialized_value = "second_value";
        };
      ]);
  assert_fails_to_parse "decode_ocaml_values('a', 'b')";

  let file = Test.write_file ("decode.me", "key,value\nsecond_key,second_value") in
  assert_parses
    (Format.sprintf "decode_ocaml_values_from_file('%s')" (Path.absolute (File.path file)))
    (DecodeOcamlValues [
        {
          TypeQuery.serialized_key = "key";
          serialized_value = "value";
        };
        {
          TypeQuery.serialized_key = "second_key";
          serialized_value = "second_value";
        };
      ])



let test_to_yojson _ =
  let open Server.Protocol in
  let assert_yojson response json =
    assert_equal
      ~printer:Yojson.Safe.pretty_to_string
      (Yojson.Safe.from_string json)
      (TypeQuery.response_to_yojson response)

  in
  assert_yojson
    (TypeQuery.Response
       (TypeQuery.Decoded {
           decoded = [
             {
               serialized_key = "first_encoded";
               kind = "Type";
               actual_key = "first";
               actual_value = Some "int";
             };
             {
               serialized_key = "first_encoded";
               kind = "Type";
               actual_key = "first";
               actual_value = Some "str";
             };
           ];
           undecodable_keys = ["no"];
         }))
    {|
      {
       "response": {
         "decoded": [
           {
             "serialized_key": "first_encoded",
             "kind": "Type",
             "key": "first",
             "value": "int"
           },
           {
             "serialized_key": "first_encoded",
             "kind": "Type",
             "key": "first",
             "value": "str"
           }
         ],
         "undecodable_keys": [ "no" ]
       }
     }
   |}


let () =
  "query">:::[
    "parse_query">::test_parse_query;
    "to_yojson">::test_to_yojson;
  ]
  |> Test.run
