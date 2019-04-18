(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open OUnit2

open Ast
open Core
open Expression
open Taint
open Test


let test_normalize_access _ =
  let assert_normalized ?(modules = []) access expected =
    let access = Test.parse_single_access ~convert:true access in
    let resolution =
      let sources =
        if List.is_empty modules then
          None
        else
          List.map
            modules
            ~f:(fun name -> Source.create ~qualifier:(Reference.create name) [])
          |> Option.some
      in
      Test.resolution ?sources ()
    in
    let normalized = AccessPath.normalize_access access ~resolution in
    let re_accessed = AccessPath.as_access normalized in
    assert_equal
      ~cmp:Expression.Access.equal_general_access
      ~printer:Expression.Access.show_general_access
      (Access.SimpleAccess access)
      re_accessed;
    assert_equal
      ~cmp:AccessPath.equal_normalized_expression
      ~printer:AccessPath.show_normalized_expression
      expected
      normalized
  in

  let local name = AccessPath.Local name in
  let global access = AccessPath.Global (Access.create access) in

  assert_normalized "a" (global "a");
  assert_normalized "a()" (AccessPath.Call { callee = global "a"; arguments = +[] });
  assert_normalized
    ~modules:["a"]
    "a.b.c"
    (AccessPath.Access { expression = global "a.b"; member = "c" });
  assert_normalized ~modules:["a"; "a.b"] "a.b.c" (global "a.b.c");
  assert_normalized
    ~modules:["a"; "a.b"]
    "a.b.c()"
    (AccessPath.Call { callee = global "a.b.c"; arguments = +[] });
  assert_normalized
    ~modules:["a"; "a.b"]
    "a.b.c.d.e"
    (AccessPath.Access {
        expression = AccessPath.Access {
            expression = global "a.b.c";
            member = "d";
          };
        member = "e";
      });

  assert_normalized "$a" (local "$a");
  assert_normalized "$a()" (AccessPath.Call { callee = local "$a"; arguments = +[] });
  assert_normalized
    "$a.b"
    (AccessPath.Access { expression = local "$a"; member = "b" })


let () =
  "taintaccesspath">:::[
    "normalize">::test_normalize_access;
  ]
  |> Test.run
