(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Pyre

open Analysis
open Test
open TypeOrder
open Annotated


let (!) name =
  Type.Primitive name


let connect ?(parameters = []) handler ~predecessor ~successor =
  connect ~parameters handler ~predecessor ~successor

let less_or_equal
    ?(constructor = fun _ -> None)
    ?(implements = fun ~protocol:_ _ -> DoesNotImplement)
    handler =
  less_or_equal { handler; constructor; implements; any_is_bottom = false }

let is_compatible_with
    ?(constructor = fun _ -> None)
    ?(implements = fun ~protocol:_ _ -> DoesNotImplement)
    handler =
  is_compatible_with { handler; constructor; implements; any_is_bottom = false }

let join
    ?(constructor = fun _ -> None)
    ?(implements = fun ~protocol:_ _ -> DoesNotImplement)
    handler =
  join { handler; constructor; implements; any_is_bottom = false }

let meet
    ?(constructor = fun _ -> None)
    ?(implements = fun ~protocol:_ _ -> DoesNotImplement)
    handler =
  meet  { handler; constructor; implements; any_is_bottom = false }

(* Butterfly:
    0 - 2
      X
    1 - 3 *)
let butterfly =
  let order = Builder.create () |> TypeOrder.handler in
  insert order Type.Bottom;
  insert order Type.Top;
  insert order !"0";
  insert order !"1";
  insert order !"2";
  insert order !"3";
  connect order ~predecessor:!"2" ~successor:Type.Top;
  connect order ~predecessor:!"3" ~successor:Type.Top;
  connect order ~predecessor:!"0" ~successor:!"2";
  connect order ~predecessor:!"0" ~successor:!"3";
  connect order ~predecessor:!"1" ~successor:!"2";
  connect order ~predecessor:!"1" ~successor:!"3";
  connect order ~predecessor:Type.Bottom ~successor:!"0";
  connect order ~predecessor:Type.Bottom ~successor:!"1";
  order


(*          0 - 3
            |   |   \
            BOTTOM  - b - 1      TOP
            |  \       /
            4 -- 2 ---           *)
let order =
  let bottom = !"bottom" in
  let order = Builder.create () |> TypeOrder.handler in
  insert order Type.Bottom;
  insert order bottom;
  insert order Type.Top;
  insert order !"0";
  insert order !"1";
  insert order !"2";
  insert order !"3";
  insert order !"4";
  insert order !"5";
  connect order ~predecessor:!"0" ~successor:!"3";
  connect order ~predecessor:!"1" ~successor:!"3";
  connect order ~predecessor:!"4" ~successor:!"2";
  connect order ~predecessor:!"3" ~successor:Type.Top;
  connect order ~predecessor:!"2" ~successor:Type.Top;
  connect order ~predecessor:Type.Bottom ~successor:bottom;
  connect order ~predecessor:bottom ~successor:!"0";
  connect order ~predecessor:bottom ~successor:!"1";
  connect order ~predecessor:bottom ~successor:!"2";
  connect order ~predecessor:bottom ~successor:!"4";
  order


(*
   TOP
    |
    A
   / \
  B   C
   \ /
    D
    |
 BOTTOM
*)
let diamond_order =
  let order = Builder.create () |> TypeOrder.handler in
  insert order Type.Bottom;
  insert order Type.Top;
  insert order !"A";
  insert order !"B";
  insert order !"C";
  insert order !"D";
  connect order ~predecessor:Type.Bottom ~successor:!"D";
  connect order ~predecessor:!"D" ~successor:!"B";
  connect order ~predecessor:!"D" ~successor:!"C";
  connect order ~predecessor:!"B" ~successor:!"A";
  connect order ~predecessor:!"C" ~successor:!"A";
  connect order ~predecessor:!"A" ~successor:Type.Top;
  order


let disconnected_order =
  let order = Builder.create () |> TypeOrder.handler in
  insert order Type.Bottom;
  insert order Type.Top;
  insert order !"A";
  insert order !"B";
  order

(*
   TOP
    |
    A
   /|
  B |
   \|
    C
    |
 BOTTOM
*)
let triangle_order =
  let order = Builder.create () |> TypeOrder.handler in
  insert order Type.Bottom;
  insert order Type.Top;
  insert order !"A";
  insert order !"B";
  insert order !"C";
  connect order ~predecessor:Type.Bottom ~successor:!"B";
  connect order ~predecessor:!"B" ~successor:!"A";
  connect order ~predecessor:!"A" ~successor:Type.Top;
  connect order ~predecessor:!"C" ~successor:!"B";
  connect order ~predecessor:!"C" ~successor:!"A";
  order


let variance_order =
  let order = Builder.create () |> TypeOrder.handler in
  let add_simple annotation =
    insert order annotation;
    connect order ~predecessor:Type.Bottom ~successor:annotation;
    connect order ~predecessor:annotation ~successor:Type.Top
  in

  insert order Type.Bottom;
  insert order Type.Any;
  insert order Type.Top;
  add_simple (Type.string);
  insert order Type.integer;
  insert order Type.float;
  connect order ~predecessor:Type.Bottom ~successor:Type.integer;
  connect order ~predecessor:Type.integer ~successor:Type.float;
  connect order ~predecessor:Type.float ~successor:Type.Top;
  insert order !"typing.Generic";

  (* Variance examples borrowed from https://www.python.org/dev/peps/pep-0483 *)
  let variable_t = Type.variable "_T" in
  let variable_t_2 = Type.variable "_T_2" in
  let variable_t_co = Type.variable "_T_co" ~variance:Covariant in
  let variable_t_contra = Type.variable "_T_contra" ~variance:Contravariant in
  add_simple variable_t;
  add_simple variable_t_co;
  add_simple variable_t_contra;
  insert order !"LinkedList";
  insert order !"Map";
  insert order !"Box";
  insert order !"Sink";
  connect
    order
    ~predecessor:!"LinkedList"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t];
  connect
    order
    ~predecessor:!"Map"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t; variable_t_2];
  connect
    order
    ~predecessor:!"Box"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_co];
  connect
    order
    ~predecessor:!"Sink"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_contra];
  insert order !"Base";
  insert order !"Derived";
  connect
    order
    ~predecessor:!"Base"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_contra];
  connect
    order
    ~predecessor:!"Derived"
    ~successor:!"Base"
    ~parameters:[variable_t_co];
  connect
    order
    ~predecessor:!"Derived"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_co];
  order


(* A much more complicated set of rules, to explore the full combination of generic types.
   These rules define a situation like this:

   _T_co = covariant
   _T_contra = contravariant

   class A(Generic[_T_co, _T_contra])
   class B(A[_T_contra, _T_co])

   Hence the graph:

      /--  A[int, int]    <  A[float, int]  ----\
      |         V                   V           |
   /--|--  A[int, float]  <  A[float, float]  --|---\
   |  V                                         V   |
   |  |                                         |   |
   V  \--  B[int, int]    >  B[float, int]  ----/   V
   |            ^                   ^               |
   \----   B[int, float]  >  B[float, float]  ------/


   Additionally, classes C and D are defined as follows:

   class C(B[int, int])
   class D(B[float, float])
*)
let multiplane_variance_order =
  let order = Builder.create () |> TypeOrder.handler in
  let add_simple annotation =
    insert order annotation;
    connect order ~predecessor:Type.Bottom ~successor:annotation;
    connect order ~predecessor:annotation ~successor:Type.Top
  in

  insert order Type.Bottom;
  insert order Type.Any;
  insert order Type.Top;
  add_simple (Type.string);
  insert order Type.integer;
  insert order Type.float;
  connect order ~predecessor:Type.Bottom ~successor:Type.integer;
  connect order ~predecessor:Type.integer ~successor:Type.float;
  connect order ~predecessor:Type.float ~successor:Type.Top;
  insert order !"typing.Generic";

  let variable_t_co = Type.variable "_T_co" ~variance:Covariant in
  let variable_t_contra = Type.variable "_T_contra" ~variance:Contravariant in
  add_simple variable_t_co;
  add_simple variable_t_contra;
  insert order !"A";
  insert order !"B";
  insert order !"C";
  insert order !"D";
  connect
    order
    ~predecessor:!"A"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_co; variable_t_contra];
  connect
    order
    ~predecessor:!"B"
    ~successor:!"A"
    ~parameters:[variable_t_contra; variable_t_co];
  connect
    order
    ~predecessor:!"B"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_contra; variable_t_co];
  connect
    order
    ~predecessor:!"C"
    ~successor:!"B"
    ~parameters:[Type.integer; Type.integer];
  connect
    order
    ~predecessor:!"D"
    ~successor:!"B"
    ~parameters:[Type.float; Type.float];
  order


(* A type order where types A and B have parallel planes.
   These rules define a situation like this:

   _T_co = covariant
   _T_contra = contravariant

   class A(Generic[_T_co, _T_contra])
   class B(A[_T_co, _T_contra])

   Hence the graph:

      /--  A[int, int]    <  A[float, int]  ----\
      |         V                   V           |
   /--|--  A[int, float]  <  A[float, float]  --|---\
   |  V                                         V   |
   |  |                                         |   |
   V  \--  B[int, int]    <  B[float, int]  ----/   V
   |            V                   V               |
   \----   B[int, float]  <  B[float, float]  ------/


   Additionally, classes C and D are defined as follows:

   class C(B[int, int])
   class D(B[float, float])
*)
let parallel_planes_variance_order =
  let order = Builder.create () |> TypeOrder.handler in
  let add_simple annotation =
    insert order annotation;
    connect order ~predecessor:Type.Bottom ~successor:annotation;
    connect order ~predecessor:annotation ~successor:Type.Top
  in

  insert order Type.Bottom;
  insert order Type.Any;
  insert order Type.Top;
  add_simple (Type.string);
  insert order Type.integer;
  insert order Type.float;
  connect order ~predecessor:Type.Bottom ~successor:Type.integer;
  connect order ~predecessor:Type.integer ~successor:Type.float;
  connect order ~predecessor:Type.float ~successor:Type.Top;
  insert order !"typing.Generic";

  let variable_t_co = Type.variable "_T_co" ~variance:Covariant in
  let variable_t_contra = Type.variable "_T_contra" ~variance:Contravariant in
  add_simple variable_t_co;
  add_simple variable_t_contra;
  insert order !"A";
  insert order !"B";
  insert order !"C";
  insert order !"D";
  connect
    order
    ~predecessor:!"A"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_co; variable_t_contra];
  connect
    order
    ~predecessor:!"B"
    ~successor:!"A"
    ~parameters:[variable_t_co; variable_t_contra];
  connect
    order
    ~predecessor:!"B"
    ~successor:!"typing.Generic"
    ~parameters:[variable_t_co; variable_t_contra];
  connect
    order
    ~predecessor:!"C"
    ~successor:!"B"
    ~parameters:[Type.integer; Type.integer];
  connect
    order
    ~predecessor:!"D"
    ~successor:!"B"
    ~parameters:[Type.float; Type.float];
  order


let default =
  let order = Builder.default () |> TypeOrder.handler in
  let variable = Type.variable "_T" in
  insert order variable;
  connect order ~predecessor:Type.Bottom ~successor:variable;
  connect order ~predecessor:variable ~successor:Type.Top;
  let other_variable = Type.variable "_T2" in
  insert order other_variable;
  connect order ~predecessor:Type.Bottom ~successor:other_variable;
  connect order ~predecessor:other_variable ~successor:Type.Top;
  let variable_covariant = Type.variable "_T_co" ~variance:Covariant in
  insert order variable_covariant;
  connect order ~predecessor:Type.Bottom ~successor:variable_covariant;
  connect order ~predecessor:variable_covariant ~successor:Type.Top;
  insert order !"typing.Sequence";
  connect order ~predecessor:!"typing.Sequence" ~successor:!"typing.Generic" ~parameters:[variable];

  insert order !"list";
  insert order !"typing.Sized";
  connect order ~predecessor:Type.Bottom ~successor:!"list";
  connect order ~predecessor:!"list" ~successor:!"typing.Sized";
  connect order ~predecessor:!"list" ~successor:!"typing.Generic" ~parameters:[variable];
  connect order ~predecessor:!"typing.Sized" ~successor:Type.Any;
  connect order ~predecessor:!"list" ~successor:!"typing.Sequence" ~parameters:[variable];

  insert order !"typing.AbstractSet";
  insert order !"set";
  connect order ~predecessor:Type.Bottom ~successor:!"set";
  connect order ~predecessor:!"set" ~successor:!"typing.Sized";
  connect order ~predecessor:!"set" ~successor:!"typing.Generic" ~parameters:[variable];
  connect
    order
    ~predecessor:!"typing.AbstractSet"
    ~successor:!"typing.Generic"
    ~parameters:[variable];
  connect order ~predecessor:!"set" ~successor:!"typing.AbstractSet" ~parameters:[variable];

  insert order !"typing.Iterator";
  connect order ~predecessor:Type.Bottom ~successor:!"typing.Iterator";
  connect order ~predecessor:!"list" ~successor:!"typing.Iterator" ~parameters:[variable];
  connect order
    ~predecessor:!"typing.Iterator"
    ~successor:!"typing.Generic"
    ~parameters:[variable_covariant];
  connect order ~predecessor:!"typing.Iterator" ~successor:Type.Top;

  insert order !"typing.Iterable";
  connect order ~predecessor:Type.Bottom ~successor:!"typing.Iterable";
  connect order
    ~predecessor:!"typing.Iterator"
    ~successor:!"typing.Iterable"
    ~parameters:[variable_covariant];
  connect order
    ~predecessor:!"typing.Iterable"
    ~successor:!"typing.Generic"
    ~parameters:[variable_covariant];
  connect order ~predecessor:!"typing.Iterable" ~successor:Type.Top;
  connect order ~predecessor:!"list" ~successor:!"typing.Iterable" ~parameters:[variable];

  insert order !"tuple";
  connect order ~predecessor:Type.Bottom ~successor:!"tuple";
  connect order ~predecessor:!"tuple" ~successor:!"typing.Iterator" ~parameters:[variable];
  connect order ~predecessor:!"tuple" ~successor:!"typing.Generic" ~parameters:[variable];

  insert order !"typing.Generator";
  connect order ~predecessor:Type.Bottom ~successor:!"typing.Generator";
  connect
    order
    ~predecessor:!"typing.Generator"
    ~successor:!"typing.Iterator"
    ~parameters:[variable];
  connect
    order
    ~predecessor:!"typing.Generator"
    ~successor:!"typing.Generic"
    ~parameters:[variable];

  insert order !"str";
  connect order ~predecessor:Type.Bottom ~successor:!"str";
  connect order ~predecessor:!"str" ~successor:!"typing.Iterable" ~parameters:[!"str"];

  insert order !"AnyIterable";
  connect order ~predecessor:Type.Bottom ~successor:!"AnyIterable";
  connect order ~predecessor:!"AnyIterable" ~successor:!"typing.Iterable";

  insert order !"typing.Mapping";
  connect
    order
    ~predecessor:!"typing.Mapping"
    ~successor:!"typing.Generic"
    ~parameters:[variable; other_variable];

  insert order !"dict";
  connect order ~predecessor:!"dict" ~successor:Type.Any ~parameters:[variable; other_variable];
  connect
    order
    ~predecessor:!"dict"
    ~successor:!"typing.Generic"
    ~parameters:[variable; other_variable];
  connect
    order
    ~predecessor:!"dict"
    ~successor:!"typing.Mapping"
    ~parameters:[variable; other_variable];
  connect order ~predecessor:!"dict" ~successor:!"typing.Iterator" ~parameters:[variable];

  insert order !"collections.OrderedDict";
  connect order ~predecessor:Type.Bottom ~successor:!"collections.OrderedDict";
  connect
    order
    ~predecessor:!"collections.OrderedDict"
    ~successor:!"typing.Generic"
    ~parameters:[variable; other_variable];
  connect
    order
    ~predecessor:!"collections.OrderedDict"
    ~successor:!"dict"
    ~parameters:[variable; other_variable];

  insert order !"PartiallySpecifiedDict";
  connect order ~predecessor:Type.Bottom ~successor:!"PartiallySpecifiedDict";
  connect order ~predecessor:!"PartiallySpecifiedDict" ~successor:!"dict" ~parameters:[!"int"];

  insert order !"OverSpecifiedDict";
  connect order ~predecessor:Type.Bottom ~successor:!"OverSpecifiedDict";
  connect order
    ~predecessor:!"OverSpecifiedDict"
    ~successor:!"dict"
    ~parameters:[!"int"; !"int"; !"str"];
  order


let test_default _ =
  let order = Builder.default () |> TypeOrder.handler in
  assert_true (less_or_equal order ~left:Type.Bottom ~right:Type.Bottom);
  assert_true (less_or_equal order ~left:Type.Bottom ~right:Type.Top);
  assert_true (less_or_equal order ~left:Type.Top ~right:Type.Top);
  assert_true (less_or_equal order ~left:Type.Top ~right:Type.Top);
  assert_false (less_or_equal order ~left:Type.Top ~right:Type.Bottom);

  (* Test special forms. *)
  let assert_has_special_form primitive_name =
    assert_true (TypeOrder.contains order (Type.Primitive primitive_name))
  in
  assert_has_special_form "typing.Tuple";
  assert_has_special_form "typing.Generic";
  assert_has_special_form "typing.Protocol";
  assert_has_special_form "typing.Callable";
  assert_has_special_form "typing.ClassVar";

  (* Object *)
  assert_true (less_or_equal order ~left:(Type.optional Type.integer) ~right:Type.object_primitive);
  assert_true (less_or_equal order ~left:(Type.list Type.integer) ~right:Type.object_primitive);
  assert_false
    (less_or_equal order ~left:Type.object_primitive ~right:(Type.optional Type.integer));

  (* Mock. *)
  assert_true (less_or_equal order ~left:(Type.Primitive "unittest.mock.Base") ~right:Type.Top);
  assert_true
    (less_or_equal order ~left:(Type.Primitive "unittest.mock.NonCallableMock") ~right:Type.Top);

  (* Numerical types. *)
  assert_true (less_or_equal order ~left:Type.integer ~right:Type.integer);
  assert_false (less_or_equal order ~left:Type.float ~right:Type.integer);
  assert_true (less_or_equal order ~left:Type.integer ~right:Type.float);
  assert_true (less_or_equal order ~left:Type.integer ~right:Type.complex);
  assert_false (less_or_equal order ~left:Type.complex ~right:Type.integer);
  assert_true (less_or_equal order ~left:Type.float ~right:Type.complex);
  assert_false (less_or_equal order ~left:Type.complex ~right:Type.float);

  assert_true (less_or_equal order ~left:Type.integer ~right:(Type.Primitive "numbers.Integral"));
  assert_true (less_or_equal order ~left:Type.integer ~right:(Type.Primitive "numbers.Rational"));
  assert_true (less_or_equal order ~left:Type.integer ~right:(Type.Primitive "numbers.Number"));
  assert_true (less_or_equal order ~left:Type.float ~right:(Type.Primitive "numbers.Real"));
  assert_true (less_or_equal order ~left:Type.float ~right:(Type.Primitive "numbers.Rational"));
  assert_true (less_or_equal order ~left:Type.float ~right:(Type.Primitive "numbers.Complex"));
  assert_true (less_or_equal order ~left:Type.float ~right:(Type.Primitive "numbers.Number"));
  assert_false (less_or_equal order ~left:Type.float ~right:(Type.Primitive "numbers.Integral"));
  assert_true (less_or_equal order ~left:Type.complex ~right:(Type.Primitive "numbers.Complex"));
  assert_false (less_or_equal order ~left:Type.complex ~right:(Type.Primitive "numbers.Real"));

  (* Test join. *)
  assert_type_equal (join order Type.integer Type.integer) Type.integer;
  assert_type_equal (join order Type.float Type.integer) Type.float;
  assert_type_equal (join order Type.integer Type.float) Type.float;
  assert_type_equal (join order Type.integer Type.complex) Type.complex;
  assert_type_equal (join order Type.float Type.complex) Type.complex;

  (* Test meet. *)
  assert_type_equal (meet order Type.integer Type.integer) Type.integer;
  assert_type_equal (meet order Type.float Type.integer) Type.integer;
  assert_type_equal (meet order Type.integer Type.float) Type.integer;
  assert_type_equal (meet order Type.integer Type.complex) Type.integer;
  assert_type_equal (meet order Type.float Type.complex) Type.float


let test_method_resolution_order_linearize _ =
  let assert_method_resolution_order ((module Handler: Handler) as order) annotation expected =
    assert_equal
      ~printer:(List.fold ~init:"" ~f:(fun sofar next -> sofar ^ (Type.show_primitive next) ^ " "))
      expected
      (method_resolution_order_linearize
         order
         annotation
         ~get_successors:(Handler.find (Handler.edges ())))
  in
  assert_method_resolution_order butterfly "3" ["3"];
  assert_method_resolution_order butterfly "0" ["0"; "3"; "2"];
  assert_method_resolution_order diamond_order "D" ["D"; "C"; "B"; "A"];
  (* The subclass gets chosen first even if after the superclass when both are inherited. *)
  assert_method_resolution_order triangle_order "C" ["C"; "B"; "A"]


let test_successors _ =
  (* Butterfly:
      0 - 2
        X
      1 - 3 *)
  assert_equal (successors butterfly "3") [];
  assert_equal (successors butterfly "0") ["3"; "2"];

  (*          0 - 3
              /   /   \
              BOTTOM - 1      TOP
              |  \       /
              4 -- 2 ---           *)
  assert_equal (successors order "3") [];
  assert_equal (successors order "0") ["3"];
  assert_equal
    (successors order "bottom")
    [
      "4";
      "2";
      "1";
      "0";
      "3";
    ]


let test_less_or_equal _ =
  (* Primitive types. *)
  assert_true (less_or_equal order ~left:Type.Bottom ~right:Type.Top);
  assert_false (less_or_equal order ~left:Type.Top ~right:Type.Bottom);

  assert_true (less_or_equal order ~left:!"0" ~right:!"0");

  assert_true (less_or_equal order ~left:Type.Bottom ~right:!"0");
  assert_true (less_or_equal order ~left:Type.Bottom ~right:!"1");
  assert_true (less_or_equal order ~left:Type.Bottom ~right:!"2");
  assert_true (less_or_equal order ~left:Type.Bottom ~right:!"3");

  assert_false (less_or_equal order ~left:!"3" ~right:Type.Bottom);
  assert_false (less_or_equal order ~left:!"2" ~right:Type.Bottom);
  assert_false (less_or_equal order ~left:!"1" ~right:Type.Bottom);
  assert_false (less_or_equal order ~left:!"0" ~right:Type.Bottom);

  assert_true (less_or_equal order ~left:!"0" ~right:!"3");
  assert_true (less_or_equal order ~left:!"1" ~right:!"3");
  assert_false (less_or_equal order ~left:!"2" ~right:!"3");

  assert_true (less_or_equal default ~left:!"list" ~right:!"typing.Sized");
  assert_true
    (less_or_equal default ~left:(Type.list Type.integer) ~right:!"typing.Sized");

  (* Parametric types. *)
  assert_true
    (less_or_equal default ~left:(Type.list Type.integer) ~right:(Type.iterator Type.integer));
  assert_false
    (less_or_equal default ~left:(Type.list Type.float) ~right:(Type.iterator Type.integer));
  assert_true
    (less_or_equal default ~left:(Type.iterator Type.integer) ~right:(Type.iterable Type.integer));
  assert_true
    (less_or_equal default ~left:(Type.iterator Type.integer) ~right:(Type.iterable Type.float));

  (* Mixed primitive and parametric types. *)
  assert_true
    (less_or_equal
       default
       ~left:(Type.string)
       ~right:(Type.iterable Type.string));

  (* Mixed tuple and parametric types. *)
  assert_true
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.integer])
       ~right:(Type.iterator Type.integer));
  assert_false
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.float])
       ~right:(Type.iterator Type.integer));
  assert_true
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.float])
       ~right:(Type.iterator Type.float));

  assert_true
    (less_or_equal
       default
       ~left:(Type.Tuple (Type.Unbounded Type.integer))
       ~right:(Type.iterator Type.integer));
  assert_false
    (less_or_equal
       default
       ~left:(Type.Tuple (Type.Unbounded Type.float))
       ~right:(Type.iterator Type.integer));

  assert_true
    (less_or_equal
       default
       ~left:(Type.Primitive "tuple")
       ~right:(Type.Tuple (Type.Unbounded Type.float)));
  assert_true
    (less_or_equal
       default
       ~left:(Type.Tuple (Type.Bounded [Type.integer; Type.integer]))
       ~right:(Type.parametric "tuple" [Type.integer]));

  (* Union types *)
  assert_true
    (less_or_equal
       default
       ~left:(Type.Optional Type.string)
       ~right:(Type.Union [Type.integer; Type.Optional Type.string]));

  (* Undeclared. *)
  assert_false (less_or_equal default ~left:(Type.undeclared) ~right:(Type.Top));
  assert_false (less_or_equal default ~left:(Type.Top) ~right:(Type.undeclared));
  assert_false (less_or_equal default ~left:(Type.undeclared) ~right:(Type.Bottom));
  assert_true (less_or_equal default ~left:(Type.Bottom) ~right:(Type.undeclared));

  (* Tuples. *)
  assert_true
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.integer])
       ~right:(Type.Tuple (Type.Unbounded Type.integer)));
  assert_true
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.integer])
       ~right:(Type.Tuple (Type.Unbounded Type.float)));
  assert_true
    (less_or_equal
       default
       ~left:(Type.tuple [Type.integer; Type.float])
       ~right:(Type.Tuple (Type.Unbounded Type.float)));

  let order =
    let order = Builder.create () |> TypeOrder.handler in
    let add_simple annotation =
      insert order annotation;
      connect order ~predecessor:Type.Bottom ~successor:annotation;
      connect order ~predecessor:annotation ~successor:Type.Top
    in

    insert order Type.Bottom;
    insert order Type.Any;
    insert order Type.Top;
    insert order Type.object_primitive;
    add_simple (Type.variable "_1");
    add_simple (Type.variable "_2");
    add_simple (Type.variable "_T");
    add_simple (Type.string);
    insert order Type.integer;
    insert order Type.float;
    connect order ~predecessor:Type.Bottom ~successor:Type.integer;
    connect order ~predecessor:Type.integer ~successor:Type.float;
    connect order ~predecessor:Type.float ~successor:Type.Top;
    add_simple !"tuple";
    insert order !"A";
    insert order !"B";
    insert order !"C";
    insert order !"typing.Generic";
    insert order !"FloatToStrCallable";
    insert order !"ParametricCallableToStr";
    insert order !"typing.Callable";
    connect order ~predecessor:Type.Bottom ~successor:!"A";

    connect
      order
      ~predecessor:!"A"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_1"; Type.variable "_2"];
    connect
      order
      ~predecessor:!"B"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_T"];
    connect
      order
      ~predecessor:!"C"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_T"];
    connect order ~predecessor:!"typing.Generic" ~successor:Type.Any;
    connect
      order
      ~predecessor:!"A"
      ~successor:!"B"
      ~parameters:[Type.tuple [Type.variable "_1"; Type.variable "_2"]];
    connect
      order
      ~predecessor:!"B"
      ~successor:!"C"
      ~parameters:[Type.union [Type.variable "_T"; Type.float]];
    connect order ~predecessor:!"typing.Generic" ~successor:Type.Any;
    connect order ~predecessor:Type.Bottom ~successor:!"FloatToStrCallable";
    connect
      order
      ~parameters:[parse_callable "typing.Callable[[float], str]"]
      ~predecessor:!"FloatToStrCallable"
      ~successor:!"typing.Callable";
    connect order ~predecessor:!"typing.Callable" ~successor:Type.Top;
    connect order ~predecessor:Type.Bottom ~successor:!"ParametricCallableToStr";
    let callable =
      let aliases annotation =
        match Type.show annotation with
        | "_T" ->
            Some (Type.variable "_T")
        | _ ->
            None
      in
      parse_callable ~aliases "typing.Callable[[_T], str]"
    in
    connect
      order
      ~parameters:[callable]
      ~predecessor:!"ParametricCallableToStr"
      ~successor:!"typing.Callable";
    connect
      order
      ~parameters:[Type.variable "_T"]
      ~predecessor:!"ParametricCallableToStr"
      ~successor:!"typing.Generic";

    let typed_dictionary = Type.Primitive "TypedDictionary" in
    let typing_mapping = Type.Primitive "typing.Mapping" in
    insert order typed_dictionary;
    insert order typing_mapping;
    connect order ~predecessor:Type.Bottom ~successor:typed_dictionary;
    connect
      order
      ~predecessor:typed_dictionary
      ~parameters:[Type.string; Type.Any]
      ~successor:typing_mapping;
    connect
      order
      ~parameters:[Type.variable "_T"; Type.variable "_T2"]
      ~predecessor:typing_mapping
      ~successor:!"typing.Generic";
    insert order (Type.Primitive "dict");

    order
  in
  assert_true
    (less_or_equal
       order
       ~left:(Type.parametric "A" [Type.integer; Type.string])
       ~right:(Type.parametric "B" [Type.tuple [Type.integer; Type.string]]));

  assert_false
    (less_or_equal
       order
       ~left:(Type.parametric "A" [Type.integer; Type.string])
       ~right:(Type.tuple [Type.integer; Type.string]));

  assert_true
    (less_or_equal
       order
       ~left:(Type.parametric "A" [Type.integer; Type.string])
       ~right:(
         Type.parametric
           "C"
           [Type.union [Type.tuple [Type.integer; Type.string]; Type.float]]));

  assert_false
    (less_or_equal
       order
       ~left:(Type.parametric "A" [Type.string; Type.integer])
       ~right:(
         Type.parametric
           "C"
           [Type.union [Type.tuple [Type.integer; Type.string]; Type.float]]));

  (* Variables. *)
  assert_true (less_or_equal order ~left:(Type.variable "T") ~right:Type.Any);
  assert_false (less_or_equal order ~left:(Type.variable "T") ~right:Type.integer);
  assert_false (less_or_equal order ~left:Type.Any ~right:(Type.variable "T"));
  assert_false (less_or_equal order ~left:Type.integer ~right:(Type.variable "T"));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable "T")
       ~right:(Type.union [Type.string; Type.variable "T"]));

  assert_false
    (less_or_equal
       order
       ~left:Type.integer
       ~right:(Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.integer]) "T"));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.string]) "T")
       ~right:(Type.union [Type.float; Type.string]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.string]) "T")
       ~right:(Type.union [Type.float; Type.string; !"A"]));
  assert_false
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.string]) "T")
       ~right:(Type.union [Type.float]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable
                ~constraints:(Type.Variable.Bound (Type.union [Type.float; Type.string]))
                "T")
       ~right:(Type.union [Type.float; Type.string; !"A"]));
  assert_false
    (less_or_equal
       order
       ~left:Type.string
       ~right:(Type.variable ~constraints:(Type.Variable.Bound (Type.string)) "T"));
  let float_string_variable =
    Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.string]) "T"
  in
  assert_true
    (less_or_equal
       order
       ~left:float_string_variable
       ~right:(Type.union [float_string_variable; !"A"]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Bound !"A") "T")
       ~right:(Type.union [
           Type.variable ~constraints:(Type.Variable.Bound !"A") "T";
           Type.string;
         ]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Bound !"A") "T")
       ~right:(Type.optional (Type.variable ~constraints:(Type.Variable.Bound !"A") "T")));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Bound (Type.optional !"A")) "T")
       ~right:(Type.optional !"A"));

  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Bound Type.integer) "T")
       ~right:(Type.union [Type.float; Type.string]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Bound Type.integer) "T")
       ~right:(Type.union [
           Type.variable ~constraints:(Type.Variable.Bound Type.integer) "T";
           Type.string;
         ]));

  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Unconstrained) "T")
       ~right:(Type.Top));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.Unconstrained) "T")
       ~right:(Type.union [
           Type.variable ~constraints:(Type.Variable.Unconstrained) "T";
           Type.string;
         ]));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable
                ~constraints:(Type.Variable.Bound (Type.union [Type.float; Type.string]))
                "T")
       ~right:(Type.union [Type.float; Type.string]));

  assert_false
    (less_or_equal
       order
       ~left:Type.integer
       ~right:(Type.variable ~constraints:(Type.Variable.Bound Type.float) "T"));
  assert_false
    (less_or_equal
       order
       ~left:Type.float
       ~right:(Type.variable ~constraints:(Type.Variable.Bound Type.integer) "T"));

  assert_false
    (less_or_equal
       order
       ~left:(Type.union [Type.string; Type.integer])
       ~right:(Type.variable
                 ~constraints:(Type.Variable.Explicit [Type.string; Type.integer])
                 "T"));
  assert_false
    (less_or_equal
       order
       ~left:Type.integer
       ~right:(Type.variable ~constraints:(Type.Variable.Explicit [Type.string]) "T"));

  assert_false
    (less_or_equal
       order
       ~left:Type.integer
       ~right:(Type.variable ~constraints:(Type.Variable.LiteralIntegers) "T"));
  assert_true
    (less_or_equal
       order
       ~left:(Type.variable ~constraints:(Type.Variable.LiteralIntegers) "T")
       ~right:Type.integer);

  (* Behavioral subtyping of callables. *)
  let less_or_equal ?implements order ~left ~right =
    let aliases = function
      | Type.Primitive "T_Unconstrained" ->
          Some (Type.variable "T_Unconstrained")
      | Type.Primitive "T_int_bool" ->
          Some (Type.variable
                  "T_int_bool"
                  ~constraints:(Type.Variable.Explicit [Type.integer; Type.bool]))
      | _ -> None
    in
    less_or_equal
      order
      ~left:(parse_callable ~aliases left)
      ~right:(parse_callable ~aliases right)
      ?implements
  in
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[str], int]"
       ~right:"typing.Callable[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable[[str], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[int], str]"
       ~right:"typing.Callable[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[int], float]"
       ~right:"typing.Callable[[int], int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable[[int], float]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[float], int]"
       ~right:"typing.Callable[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable[[float], int]");

  (* Named vs. anonymous callables. *)
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable('foo')[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[str], int]"
       ~right:"typing.Callable('foo')[[int], int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable('foo')[[int], int]"
       ~right:"typing.Callable[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable('foo')[[str], int]"
       ~right:"typing.Callable[[int], int]");

  (* Named callables. *)
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable('foo')[[int], int]"
       ~right:"typing.Callable('foo')[[int], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable('bar')[[str], int]"
       ~right:"typing.Callable('foo')[[int], int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable('foo')[[int], int]"
       ~right:"typing.Callable('bar')[[int], int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable('foo')[[str], int]"
       ~right:"typing.Callable('foo')[[int], int]");

  (* Undefined callables. *)
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[..., int]"
       ~right:"typing.Callable[..., float]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[int], int]"
       ~right:"typing.Callable[..., int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[..., int]"
       ~right:"typing.Callable[[int], float]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, object), Keywords(kwargs, object)], int]"
       ~right:"typing.Callable[..., int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, int), Keywords(kwargs, object)], int]"
       ~right:"typing.Callable[..., int]");

  (* Callable classes. *)
  assert_true
    (less_or_equal
       order
       ~left:"FloatToStrCallable"
       ~right:"typing.Callable[[float], str]");
  (* Subtyping is handled properly for callable classes. *)
  assert_true
    (less_or_equal
       order
       ~left:"FloatToStrCallable"
       ~right:"typing.Callable[[int], str]");
  assert_false
    (less_or_equal
       order
       ~left:"FloatToStrCallable"
       ~right:"typing.Callable[[float], int]");
  (* Parametric classes are also callables. *)
  assert_true
    (less_or_equal
       order
       ~left:"ParametricCallableToStr[int]"
       ~right:"typing.Callable[[int], str]");
  assert_true
    (less_or_equal
       order
       ~left:"ParametricCallableToStr[float]"
       ~right:"typing.Callable[[int], str]");
  assert_false
    (less_or_equal
       order
       ~left:"ParametricCallableToStr[int]"
       ~right:"typing.Callable[[float], str]");
  assert_false
    (less_or_equal
       order
       ~left:"ParametricCallableToStr[int]"
       ~right:"typing.Callable[[int], int]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, int)], str]"
       ~right:"typing.Callable[[int], str]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, int)], str]"
       ~right:"typing.Callable[[int, int], str]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, str)], str]"
       ~right:"typing.Callable[[int], str]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, int)], str]"
       ~right:"typing.Callable[[Named(arg, int)], str]");

  (* Callables with keyword arguments. *)
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[Keywords(kwargs, int)], str]"
       ~right:"typing.Callable[[Named(arg, int)], str]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, int), Keywords(kwargs, int)], str]"
       ~right:"typing.Callable[[Named(arg, int)], str]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[Variable(args, str), Keywords(kwargs, int)], str]"
       ~right:"typing.Callable[[Named(arg, int)], str]");

  (* Generic callables *)
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
       ~right:"typing.Callable[[Named(arg, int)], str]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
       ~right:"typing.Callable[[Named(arg, int)], int]");
  assert_false
    (less_or_equal
       order
       ~right:"typing.Callable[[Named(arg, int)], str]"
       ~left:"typing.Callable[[T_Unconstrained], T_Unconstrained]");
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[[T_int_bool], T_int_bool]"
       ~right:"typing.Callable[[Named(arg, int)], int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Callable[[T_int_bool], T_int_bool]"
       ~right:"typing.Callable[[Named(arg, str)], str]");
  (* Callables with overloads *)
  assert_true
    (less_or_equal
       order
       ~left:"typing.Callable[..., $bottom][[[int], int][[float], float]]"
       ~right:"typing.Callable[[int], int]");

  (* TypedDictionaries *)
  assert_true
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('foo', str), ('bar', int), ('baz', int))]"
       ~right:"mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int))]");
  assert_true
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', False, ('foo', str), ('bar', int), ('baz', int))]"
       ~right:"mypy_extensions.TypedDict[('Beta', False, ('foo', str), ('bar', int))]");
  assert_false
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', False, ('foo', str), ('bar', int), ('baz', int))]"
       ~right:"mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int))]");
  assert_false
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('foo', str), ('bar', int), ('baz', int))]"
       ~right:"mypy_extensions.TypedDict[('Beta', False, ('foo', str), ('bar', int))]");
  assert_false
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('foo', str), ('bar', float))]"
       ~right:"mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int))]");
  assert_true
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str))]"
       ~right:"mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int))]");

  assert_true
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', int))]"
       ~right:"typing.Mapping[str, typing.Any]");
  assert_true
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', False, ('bar', int), ('foo', int))]"
       ~right:"typing.Mapping[str, typing.Any]");
  assert_false
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', int))]"
       ~right:"typing.Mapping[str, int]");
  assert_false
    (less_or_equal
       order
       ~left:"typing.Mapping[str, typing.Any]"
       ~right:"mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', int))]");
  assert_false
    (less_or_equal
       order
       ~left:"mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', int))]"
       ~right:"dict[str, typing.Any]");

  (* Literals *)
  assert_true
    (less_or_equal
       order
       ~left:"typing_extensions.Literal['a']"
       ~right:"typing_extensions.Literal['a']");
  assert_true
    (less_or_equal
       order
       ~left:"typing_extensions.Literal['a']"
       ~right:"str");
  assert_false
    (less_or_equal
       order
       ~left:"str"
       ~right:"typing_extensions.Literal['a']");
  assert_true
    (less_or_equal
       order
       ~left:"typing_extensions.Literal['a']"
       ~right:"typing_extensions.Literal['a', 'b']");

  (* Callback protocols *)
  let implements ~protocol callable =
    match protocol, callable with
    | Type.Primitive "MatchesProtocol", Type.Callable _  ->
        TypeOrder.Implements { parameters = [] }
    | Type.Parametric { name = "B"; _ }, Type.Callable _  ->
        TypeOrder.Implements { parameters = [Type.integer] }
    | _ ->
        TypeOrder.DoesNotImplement
  in
  assert_true
    (less_or_equal
       order
       ~implements
       ~left:"typing.Callable[[int], str]"
       ~right:"MatchesProtocol");
  assert_false
    (less_or_equal
       order
       ~implements
       ~left:"typing.Callable[[int], str]"
       ~right:"DoesNotMatchProtocol");
  assert_true
    (less_or_equal
       order
       ~implements
       ~left:"typing.Callable[[int], str]"
       ~right:"B[int]");
  assert_false
    (less_or_equal
       order
       ~implements
       ~left:"typing.Callable[[int], str]"
       ~right:"B[str]");

  let assert_less_or_equal ?(source = "") ~left ~right expected_result =
    let resolution =
      let source =
        parse source
        |> Preprocessing.preprocess
      in
      AnnotatedTest.populate_with_sources (source :: Test.typeshed_stubs ())
      |> (fun environment -> TypeCheck.resolution environment ())
    in
    let parse_annotation annotation =
      annotation
      |> parse_single_expression
      |> Resolution.parse_annotation resolution
    in
    let left, right = parse_annotation left, parse_annotation right in
    assert_equal
      ~printer:(Printf.sprintf "%B")
      expected_result
      (Resolution.less_or_equal resolution ~left ~right)
  in
  assert_less_or_equal
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1")
      T2 = TypeVar("T2")
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
    |}
    ~left:"NonGenericChild"
    ~right:"GenericBase[typing.Any, typing.Any]"
    true;
  (* This should get filtered by mismatch with any postprocessing *)
  assert_less_or_equal
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1")
      T2 = TypeVar("T2")
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
    |}
    ~left:"NonGenericChild"
    ~right:"GenericBase[int, str]"
    false;
  assert_less_or_equal
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1", contravariant=True)
      T2 = TypeVar("T2", contravariant=True)
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
    |}
    ~left:"GenericBase[typing.Any, typing.Any]"
    ~right:"GenericBase[int, str]"
    true;
  assert_less_or_equal
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1", contravariant=True)
      T2 = TypeVar("T2", contravariant=True)
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
    |}
    ~left:"NonGenericChild"
    ~right:"GenericBase[int, str]"
    true;
  assert_less_or_equal
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1")
      T2 = TypeVar("T2")
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
      class Grandchild(NonGenericChild): pass
    |}
    ~left:"Grandchild"
    ~right:"GenericBase[typing.Any, typing.Any]"
    true;
  ()


let test_is_compatible_with _ =
  let assert_is_compatible ?(order = default) left right =
    assert_true (is_compatible_with order ~left ~right);
  in
  let assert_not_compatible ?(order = default) left right =
    assert_false (is_compatible_with order ~left ~right);
  in
  let list_of_integer = Type.list Type.integer in
  let list_of_float = Type.list Type.float in
  let list_of_string = Type.list Type.string in

  (* Basic *)
  assert_is_compatible list_of_integer list_of_integer;
  assert_is_compatible list_of_integer list_of_float;
  assert_not_compatible list_of_float list_of_integer;
  assert_not_compatible list_of_integer list_of_string;

  (* Optional *)
  assert_is_compatible list_of_integer (Type.optional list_of_integer);
  assert_is_compatible
    (Type.optional list_of_integer) (Type.optional list_of_integer);
  assert_is_compatible list_of_integer (Type.optional list_of_float);
  assert_is_compatible
    (Type.optional list_of_integer) (Type.optional list_of_float);
  assert_not_compatible list_of_float (Type.optional list_of_integer);
  assert_not_compatible list_of_integer (Type.optional list_of_string);

  (* Tuple *)
  assert_is_compatible
    (Type.tuple [list_of_integer; list_of_string])
    (Type.tuple [list_of_integer; list_of_string]);
  assert_is_compatible
    (Type.tuple [list_of_integer; list_of_string])
    (Type.tuple [list_of_float; list_of_string]);
  assert_is_compatible
    (Type.tuple [list_of_string; list_of_integer])
    (Type.tuple [list_of_string; list_of_float]);
  assert_is_compatible
    (Type.tuple [list_of_integer; list_of_integer])
    (Type.tuple [list_of_float; list_of_float]);
  assert_is_compatible
    (Type.tuple [list_of_integer; list_of_integer])
    (Type.Tuple (Unbounded list_of_integer));
  assert_is_compatible
    (Type.tuple [list_of_integer; list_of_integer])
    (Type.Tuple (Unbounded list_of_float));
  assert_not_compatible
    (Type.tuple [list_of_integer; list_of_string])
    (Type.tuple [list_of_string; list_of_string]);
  assert_not_compatible
    (Type.tuple [list_of_float; list_of_integer])
    (Type.tuple [list_of_integer; list_of_float]);
  assert_not_compatible
    (Type.tuple [list_of_string; list_of_integer])
    (Type.Tuple (Unbounded list_of_float));

  (* Union *)
  assert_is_compatible
    list_of_integer (Type.union [list_of_integer]);
  assert_is_compatible
    list_of_integer (Type.union [list_of_float]);
  assert_is_compatible
    list_of_float (Type.union [list_of_float; list_of_integer]);
  assert_is_compatible
    list_of_string (Type.union [list_of_float; list_of_string]);
  assert_is_compatible
    list_of_string (Type.union [list_of_float; Type.optional list_of_string]);
  assert_not_compatible
    list_of_string (Type.union [list_of_float; list_of_integer]);

  (* Parametric *)
  assert_is_compatible
    (Type.dictionary ~key:list_of_integer ~value:list_of_string)
    (Type.dictionary ~key:list_of_integer ~value:list_of_string);
  assert_is_compatible
    (Type.dictionary ~key:list_of_integer ~value:list_of_string)
    (Type.dictionary ~key:list_of_float ~value:list_of_string);
  assert_is_compatible
    (Type.dictionary ~key:list_of_string ~value:list_of_integer)
    (Type.dictionary ~key:list_of_string ~value:list_of_float);
  assert_is_compatible
    (Type.dictionary ~key:list_of_integer ~value:list_of_integer)
    (Type.dictionary ~key:list_of_float ~value:list_of_float);
  assert_not_compatible
    (Type.dictionary ~key:list_of_integer ~value:list_of_integer)
    (Type.dictionary ~key:list_of_string ~value:list_of_integer);
  assert_not_compatible
    (Type.dictionary ~key:list_of_string ~value:list_of_string)
    (Type.dictionary ~key:list_of_string ~value:list_of_integer);
  assert_not_compatible
    (Type.dictionary ~key:list_of_string ~value:list_of_integer)
    list_of_string;
  assert_not_compatible
    list_of_string
    (Type.dictionary ~key:list_of_string ~value:list_of_integer);

  ()


let test_less_or_equal_variance _ =
  let assert_strict_less ~order ~right ~left =
    assert_true (less_or_equal order ~left ~right);
    assert_false (less_or_equal order ~left:right ~right:left)
  in
  (* Invariant. *)
  assert_false
    (less_or_equal
       variance_order
       ~left:(Type.parametric "LinkedList" [Type.integer])
       ~right:(Type.parametric "LinkedList" [Type.float]));
  assert_false
    (less_or_equal
       variance_order
       ~left:(Type.parametric "LinkedList" [Type.float])
       ~right:(Type.parametric "LinkedList" [Type.integer]));
  assert_false
    (less_or_equal
       variance_order
       ~left:(Type.parametric "LinkedList" [Type.integer])
       ~right:(Type.parametric "LinkedList" [Type.Any]));
  assert_false
    (less_or_equal
       variance_order
       ~left:(Type.parametric "LinkedList" [Type.Any])
       ~right:(Type.parametric "LinkedList" [Type.integer]));
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "LinkedList" [Type.integer])
    ~right:(Type.parametric "LinkedList" [Type.Top]);
  (* Covariant. *)
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Box" [Type.integer])
    ~right:(Type.parametric "Box" [Type.float]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Box" [Type.integer])
    ~right:(Type.parametric "Box" [Type.Any]);
  (* Contravariant. *)
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Sink" [Type.float])
    ~right:(Type.parametric "Sink" [Type.integer]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Sink" [Type.Any])
    ~right:(Type.parametric "Sink" [Type.integer]);
  (* More complex rules. *)
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Derived" [Type.integer])
    ~right:(Type.parametric "Derived" [Type.float]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Derived" [Type.integer])
    ~right:(Type.parametric "Base" [Type.integer]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Derived" [Type.float])
    ~right:(Type.parametric "Base" [Type.float]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Base" [Type.float])
    ~right:(Type.parametric "Base" [Type.integer]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Derived" [Type.integer])
    ~right:(Type.parametric "Base" [Type.float]);
  assert_strict_less
    ~order:variance_order
    ~left:(Type.parametric "Derived" [Type.float])
    ~right:(Type.parametric "Base" [Type.integer]);
  (* Multiplane variance. *)
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "A" [Type.integer; Type.float])
    ~right:(Type.parametric "A" [Type.float; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.integer])
    ~right:(Type.parametric "B" [Type.integer; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.integer; Type.integer])
    ~right:(Type.parametric "A" [Type.integer; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.integer; Type.integer])
    ~right:(Type.parametric "A" [Type.integer; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.integer; Type.integer])
    ~right:(Type.parametric "A" [Type.float; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.float])
    ~right:(Type.parametric "A" [Type.integer; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.float])
    ~right:(Type.parametric "A" [Type.integer; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.float])
    ~right:(Type.parametric "A" [Type.float; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.integer])
    ~right:(Type.parametric "A" [Type.integer; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.integer])
    ~right:(Type.parametric "A" [Type.integer; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.integer])
    ~right:(Type.parametric "A" [Type.float; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "B" [Type.float; Type.integer])
    ~right:(Type.parametric "A" [Type.float; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "C" [])
    ~right:(Type.parametric "A" [Type.float; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:!"C"
    ~right:(Type.parametric "A" [Type.float; Type.float]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:(Type.parametric "D" [])
    ~right:(Type.parametric "A" [Type.integer; Type.integer]);
  assert_strict_less
    ~order:multiplane_variance_order
    ~left:!"D"
    ~right:(Type.parametric "A" [Type.integer; Type.integer]);
  assert_false
    (less_or_equal
       parallel_planes_variance_order
       ~left:(Type.parametric "C" [])
       ~right:(Type.parametric "A" [Type.float; Type.float]));
  assert_false
    (less_or_equal
       parallel_planes_variance_order
       ~left:!"C"
       ~right:(Type.parametric "A" [Type.float; Type.float]));
  assert_false
    (less_or_equal
       parallel_planes_variance_order
       ~left:(Type.parametric "D" [])
       ~right:(Type.parametric "A" [Type.integer; Type.integer]));
  assert_false
    (less_or_equal
       parallel_planes_variance_order
       ~left:!"D"
       ~right:(Type.parametric "A" [Type.integer; Type.integer]));
  ()


let test_join _ =
  let assert_join ?(order = default) ?(aliases = (fun _ -> None)) left right expected =
    let parse_annotation source =
      let integer = try Int.of_string source |> ignore; true with _ -> false in
      if integer then
        Type.Primitive source
      else
        parse_single_expression source
        |> Type.create ~aliases
    in
    assert_type_equal
      (parse_annotation expected)
      (join order (parse_annotation left) (parse_annotation right))
  in


  (* Primitive types. *)
  assert_join "list" "typing.Sized" "typing.Sized";
  assert_join "typing.Sized" "list" "typing.Sized";
  assert_join "typing.List[int]" "typing.Sized" "typing.Sized";
  assert_join "int" "str" "typing.Union[int, str]";

  (* Parametric types. *)
  assert_join "typing.List[float]" "typing.List[float]" "typing.List[float]";
  assert_join "typing.List[float]" "typing.List[int]" "typing.List[typing.Any]";
  assert_join "typing.List[int]" "typing.Iterator[int]" "typing.Iterator[int]";
  assert_join "typing.Iterator[int]" "typing.List[int]" "typing.Iterator[int]";
  assert_join "typing.List[float]" "typing.Iterator[int]" "typing.Iterator[float]";
  assert_join "typing.List[float]" "float[int]" "typing.Union[typing.List[float], float[int]]";
  (* TODO(T41082573) throw here instead of unioning *)
  assert_join "typing.Tuple[int, int]" "typing.Iterator[int]" "typing.Iterator[int]";

  (* Optionals. *)
  assert_join "str" "typing.Optional[str]" "typing.Optional[str]";
  assert_join "str" "typing.Optional[$bottom]" "typing.Optional[str]";
  assert_join "typing.Optional[$bottom]" "str" "typing.Optional[str]";

  (* Handles `[] or optional_list`. *)
  assert_join "typing.List[$bottom]" "typing.Optional[typing.List[int]]" "typing.List[int]";
  assert_join "typing.Optional[typing.List[int]]" "typing.List[$bottom]" "typing.List[int]";
  assert_join "typing.Optional[typing.Set[int]]" "typing.Set[$bottom]" "typing.Set[int]";

  (* Union types. *)
  assert_join
    "typing.Optional[bool]"
    "typing.Union[int, typing.Optional[bool]]"
    "typing.Union[int, typing.Optional[bool]]";
  assert_join "typing.Union[int, str]" "typing.Union[int, bytes]" "typing.Union[int, str, bytes]";
  assert_join
    "typing.Union[int, str]"
    "typing.Optional[$bottom]"
    "typing.Optional[typing.Union[int, str]]";

  assert_join
    "typing.Dict[str, str]"
    "typing.Dict[str, typing.List[str]]"
    "typing.Dict[str, typing.Any]";

  assert_join "typing.Union[typing.List[int], typing.Set[int]]" "typing.Sized" "typing.Sized";
  assert_join "typing.Tuple[int, ...]" "typing.Iterable[int]" "typing.Iterable[int]";
  assert_join "typing.Tuple[str, ...]" "typing.Iterator[str]" "typing.Iterator[str]";
  assert_join
    "typing.Tuple[int, ...]"
    "typing.Iterable[str]"
    "typing.Iterable[typing.Union[int, str]]";

  assert_join
    "typing.Optional[float]"
    "typing.Union[float, int]"
    "typing.Optional[typing.Union[float, int]]";

  (* Undeclared. *)
  assert_join "typing.Undeclared" "int" "typing.Union[typing.Undeclared, int]";
  assert_join "int" "typing.Undeclared" "typing.Union[typing.Undeclared, int]";
  let assert_join_types ?(order = default) left right expected =
    assert_type_equal
      expected
      (join order left right)
  in
  assert_join_types
    Type.undeclared
    Type.Top
    (Type.Union [Type.undeclared; Type.Top]);
  assert_join_types
    Type.Top
    Type.undeclared
    (Type.Union [Type.undeclared; Type.Top]);
  assert_join_types Type.undeclared Type.Bottom Type.undeclared;
  assert_join_types Type.Bottom Type.undeclared Type.undeclared;
  assert_join_types
    ~order
    !"0"
    Type.undeclared
    (Type.Union [!"0"; Type.undeclared]);
  assert_join_types
    ~order
    Type.undeclared
    !"0"
    (Type.Union [!"0"; Type.undeclared]);

  assert_join
    "typing.Tuple[int, int]"
    "typing.Tuple[int, int, str]"
    "typing.Union[typing.Tuple[int, int], typing.Tuple[int, int, str]]";

  let order =
    let order = Builder.create () |> TypeOrder.handler in
    let add_simple annotation =
      insert order annotation;
      connect order ~predecessor:Type.Bottom ~successor:annotation;
      connect order ~predecessor:annotation ~successor:Type.Top
    in

    insert order Type.Bottom;
    insert order Type.Any;
    insert order Type.Top;
    add_simple Type.object_primitive;
    add_simple (Type.variable "_1");
    add_simple (Type.variable "_2");
    add_simple (Type.variable "_T");
    add_simple (Type.string);
    insert order Type.integer;
    insert order Type.float;
    insert order !"A";
    insert order !"B";
    insert order !"C";
    insert order !"CallableClass";
    insert order !"ParametricCallableToStr";
    insert order !"typing.Callable";
    insert order !"typing.Generic";

    connect order ~predecessor:Type.Bottom ~successor:Type.integer;
    connect order ~predecessor:Type.integer ~successor:Type.float;
    connect order ~predecessor:Type.float ~successor:Type.object_primitive;

    connect order ~predecessor:Type.Bottom ~successor:!"A";

    connect
      order
      ~predecessor:!"A"
      ~successor:!"B"
      ~parameters:[Type.tuple [Type.variable "_1"; Type.variable "_2"]];
    connect
      order
      ~predecessor:!"A"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_1"; Type.variable "_2"];
    connect
      order
      ~predecessor:!"B"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_T"];
    connect
      order
      ~predecessor:!"B"
      ~successor:!"C"
      ~parameters:[Type.union [Type.variable "_T"; Type.float]];
    connect
      order
      ~predecessor:!"C"
      ~successor:!"typing.Generic"
      ~parameters:[Type.variable "_T"];
    connect order ~predecessor:!"typing.Generic" ~successor:Type.Any;
    connect order ~predecessor:Type.Bottom ~successor:!"CallableClass";
    connect
      order
      ~parameters:[parse_callable "typing.Callable[[int], str]"]
      ~predecessor:!"CallableClass"
      ~successor:!"typing.Callable";
    connect order ~predecessor:!"typing.Callable" ~successor:Type.Top;
    let callable =
      let aliases annotation =
        match Type.show annotation with
        | "_T" ->
            Some (Type.variable "_T")
        | _ ->
            None
      in
      parse_callable ~aliases "typing.Callable[[_T], str]"
    in
    connect order ~predecessor:Type.Bottom ~successor:!"ParametricCallableToStr";
    connect
      order
      ~parameters:[callable]
      ~predecessor:!"ParametricCallableToStr"
      ~successor:!"typing.Callable";
    connect
      order
      ~parameters:[Type.variable "_T"]
      ~predecessor:!"ParametricCallableToStr"
      ~successor:!"typing.Generic";

    order
  in
  let aliases =
    Type.Table.of_alist_exn [
      Type.Primitive "_1", Type.variable "_1";
      Type.Primitive "_2", Type.variable "_2";
      Type.Primitive "_T", Type.variable "_T";
    ]
    |> Type.Table.find
  in

  assert_join
    ~order
    ~aliases
    "A[int, str]"
    "C[$bottom]"
    "C[typing.Union[float, typing.Tuple[int, str]]]";

  assert_join ~order:disconnected_order "A" "B" "typing.Union[A, B]";

  assert_join
    "typing.Type[int]"
    "typing.Type[str]"
    "typing.Type[typing.Union[int, str]]";

  (* Callables. *)
  assert_join
    "typing.Callable[..., int]"
    "typing.Callable[..., str]"
    "typing.Callable[..., typing.Union[int, str]]";
  assert_join
    "typing.Callable[..., int]"
    "typing.Callable[..., $bottom]"
    "typing.Callable[..., int]";

  assert_join
    "typing.Callable('derp')[..., int]"
    "typing.Callable('derp')[..., int]"
    "typing.Callable('derp')[..., int]";
  assert_join
    "typing.Callable('derp')[..., int]"
    "typing.Callable('other')[..., int]"
    "typing.Callable[..., int]";

  (* Do not join with overloads. *)
  assert_join
    "typing.Callable[..., int][[..., str]]"
    "typing.Callable[..., int]"
    "typing.Union[typing.Callable[..., int][[..., str]], typing.Callable[..., int]]";

  assert_join
    "typing.Callable[[Named(a, int), Named(b, str)], int]"
    "typing.Callable[[Named(a, int), Named(b, str)], int]"
    "typing.Callable[[Named(a, int), Named(b, str)], int]";
  assert_join
    "typing.Callable[[Named(a, int)], int]"
    "typing.Callable[[int], int]"
    "typing.Callable[[int], int]";

  (* Behavioral subtyping is preserved. *)
  assert_join
    "typing.Callable[[Named(a, str)], int]"
    "typing.Callable[[Named(a, int)], int]"
    "typing.Callable[[Named(a, $bottom)], int]";
  assert_join
    "typing.Callable[..., int]"
    "typing.Callable[..., $bottom]"
    "typing.Callable[..., int]";
  assert_join
    "typing.Callable[[int], int]"
    "typing.Callable[[Named(a, int)], int]"
    "typing.Callable[[int], int]";
  assert_join
    "typing.Callable[[Named(b, int)], int]"
    "typing.Callable[[Named(a, int)], int]"
    "typing.Union[typing.Callable[[Named(b, int)], int], typing.Callable[[Named(a, int)], int]]";

  (* Classes with __call__ are callables. *)
  assert_join
    ~order
    "CallableClass"
    "typing.Callable[[int], str]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], str]"
    "CallableClass"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], int]"
    "CallableClass"
    "typing.Callable[[int], typing.Union[int, str]]";
  assert_join
    ~order
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], str]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], str]"
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], int]"
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], typing.Union[int, str]]";

  assert_join
    ~order
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], str]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[float], str]"
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], str]"
    "ParametricCallableToStr[float]"
    "typing.Callable[[int], str]";
  assert_join
    ~order
    "typing.Callable[[int], int]"
    "ParametricCallableToStr[int]"
    "typing.Callable[[int], typing.Union[int, str]]";

  (* TypedDictionaries *)
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int), ('baz', int))]"
    "mypy_extensions.TypedDict[('$anonymous', True, ('foo', str), ('bar', int))]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', False, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', False, ('foo', str), ('bar', int), ('baz', int))]"
    "mypy_extensions.TypedDict[('$anonymous', False, ('foo', str), ('bar', int))]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', str))]"
    "mypy_extensions.TypedDict[('$anonymous', True)]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', int))]"
    "typing.Mapping[str, typing.Any]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', False, ('foo', str), ('bar', int), ('baz', int))]"
    "typing.Mapping[str, typing.Any]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', str), ('foo', str), ('ben', str))]"
    "typing.Mapping[str, str]"
    "typing.Mapping[str, typing.Any]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', False, ('bar', str), ('foo', str), ('ben', str))]"
    "typing.Mapping[str, str]"
    "typing.Mapping[str, typing.Any]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', str), ('foo', str), ('ben', str))]"
    "typing.Mapping[int, str]"
    "typing.Mapping[typing.Any, typing.Any]";
  assert_join
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', str), ('foo', str), ('ben', str))]"
    "typing.Dict[str, str]"
    (
      "typing.Union[" ^
      "mypy_extensions.TypedDict[('Alpha', True, ('bar', str), ('foo', str), ('ben', str))], " ^
      "typing.Dict[str, str]" ^
      "]"
    );

  (* Variables. *)
  assert_type_equal
    (join order Type.integer (Type.variable "T"))
    Type.object_primitive;
  assert_type_equal
    (join order Type.integer (Type.variable ~constraints:(Type.Variable.Bound Type.string) "T"))
    (Type.union [Type.string; Type.integer]);
  assert_type_equal
    (join
       order
       Type.string
       (Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.integer]) "T"))
    (Type.union [Type.float; Type.integer; Type.string]);
  assert_type_equal
    (join
       order
       Type.string
       (Type.variable ~constraints:(Type.Variable.LiteralIntegers) "T"))
    (Type.union [Type.integer; Type.string]);
  assert_type_equal
    (join
       order
       (Type.literal_integer 7)
       (Type.variable ~constraints:(Type.Variable.LiteralIntegers) "T"))
    Type.integer;

  (* Variance. *)
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.integer])
       (Type.parametric "LinkedList" [Type.Top]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Top])
       (Type.parametric "LinkedList" [Type.integer]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Bottom])
       (Type.parametric "LinkedList" [Type.Top]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Top])
       (Type.parametric "LinkedList" [Type.Bottom]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Any])
       (Type.parametric "LinkedList" [Type.Top]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Top])
       (Type.parametric "LinkedList" [Type.Any]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Top])
       (Type.parametric "LinkedList" [Type.Top]))
    (Type.parametric "LinkedList" [Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "Map" [Type.integer; Type.integer])
       (Type.parametric "Map" [Type.Top; Type.Top]))
    (Type.parametric "Map" [Type.Top; Type.Top]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "Map" [Type.integer; Type.integer])
       (Type.parametric "Map" [Type.Top; Type.integer]))
    (Type.parametric "Map" [Type.Top; Type.integer]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "Map" [Type.integer; Type.integer])
       (Type.parametric "Map" [Type.Top; Type.string]))
    (Type.parametric "Map" [Type.Top; Type.Any]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.integer])
       (Type.parametric "LinkedList" [Type.Any]))
    (Type.parametric "LinkedList" [Type.Any]);
  assert_type_equal
    (join
       variance_order
       (Type.parametric "LinkedList" [Type.Any])
       (Type.parametric "LinkedList" [Type.integer]))
    (Type.parametric "LinkedList" [Type.Any]);
  let variance_aliases =
    Type.Table.of_alist_exn [
      Type.Primitive "_T", Type.variable "_T";
      Type.Primitive "_T_co", Type.variable "_T_co" ~variance:Covariant;
      Type.Primitive "_T_contra", Type.variable "_T_contra" ~variance:Contravariant;
    ]
    |> Type.Table.find
  in
  assert_join
    ~order:variance_order
    ~aliases:variance_aliases
    "Derived[int]"
    "Base[int]"
    "Base[int]";
  assert_join
    ~order:variance_order
    ~aliases:variance_aliases
    "Derived[float]"
    "Base[float]"
    "Base[float]";
  assert_join
    ~order:variance_order
    ~aliases:variance_aliases
    "Derived[int]"
    "Base[float]"
    "Base[float]";
  assert_join
    ~order:variance_order
    ~aliases:variance_aliases
    "Derived[float]"
    "Base[int]"
    "Base[int]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[int, float]"
    "A[int, float]"
    "A[int, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[int, int]"
    "A[int, float]"
    "A[int, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[float, int]"
    "A[int, float]"
    "A[int, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[float, float]"
    "A[int, float]"
    "A[int, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[int, float]"
    "A[float, float]"
    "A[float, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[int, int]"
    "A[float, float]"
    "A[float, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[float, int]"
    "A[float, float]"
    "A[float, float]";
  assert_join
    ~order:multiplane_variance_order
    ~aliases:variance_aliases
    "B[float, float]"
    "A[float, float]"
    "A[float, float]";
  assert_join
    ~order:parallel_planes_variance_order
    ~aliases:variance_aliases
    "B[float, float]"
    "A[int, float]"
    "A[float, float]";
  assert_join
    ~order:parallel_planes_variance_order
    ~aliases:variance_aliases
    "B[float, float]"
    "A[int, int]"
    "A[float, int]";

  (* Literals *)
  assert_type_equal
    (join order (Type.literal_string "A") (Type.literal_string "A"))
    (Type.literal_string "A");
  assert_type_equal
    (join order (Type.literal_string "A") (Type.literal_string "B"))
    Type.string;
  assert_type_equal
    (join order (Type.literal_string "A") (Type.integer))
    (Type.union [Type.string; Type.integer]);

  let assert_join ?(source = "") ~left ~right expected_result =
    let resolution =
      let source =
        parse source
        |> Preprocessing.preprocess
      in
      AnnotatedTest.populate_with_sources (source :: Test.typeshed_stubs ())
      |> (fun environment -> TypeCheck.resolution environment ())
    in
    let parse_annotation annotation =
      annotation
      |> parse_single_expression
      |> Resolution.parse_annotation resolution
    in
    let left, right = parse_annotation left, parse_annotation right in
    assert_type_equal
      (parse_annotation expected_result)
      (Resolution.join resolution left right)
  in
  assert_join
    ~source:{|
      from typing import Generic, TypeVar
      T1 = TypeVar("T1", covariant=True)
      T2 = TypeVar("T2", covariant=True)
      class GenericBase(Generic[T1, T2]): pass
      class NonGenericChild(GenericBase): pass
    |}
    ~left:"NonGenericChild"
    ~right:"GenericBase[int, str]"
    "GenericBase[typing.Any, typing.Any]";
  ()


let test_meet _ =
  let assert_meet ?(order = default) ?(aliases = (fun _ -> None)) left right expected =
    let parse_annotation source =
      let integer = try Int.of_string source |> ignore; true with _ -> false in
      if integer then
        Type.Primitive source
      else
        parse_single_expression source
        |> Type.create ~aliases
    in
    assert_type_equal
      (parse_annotation expected)
      (meet order (parse_annotation left) (parse_annotation right))
  in

  (* Special elements. *)
  assert_meet "typing.List[float]" "typing.Any" "typing.List[float]";

  (* Primitive types. *)
  assert_meet "list" "typing.Sized" "list";
  assert_meet "typing.Sized" "list" "list";
  assert_meet "typing.List[int]" "typing.Sized" "typing.List[int]";

  (* Unions. *)
  assert_meet "typing.Union[int, str]" "typing.Union[int, bytes]" "int";
  assert_meet "typing.Union[int, str]" "typing.Union[str, int]" "typing.Union[int, str]";
  (* TODO(T39185893): current implementation of meet has some limitations which need to be fixed *)
  assert_meet
    "typing.Union[int, str]"
    "typing.Union[int, typing.Optional[str]]"
    "$bottom";
  assert_meet
    "typing.Union[int, typing.Optional[str]]"
    "typing.Optional[str]"
    "$bottom";

  (* Parametric types. *)
  assert_meet "typing.List[int]" "typing.Iterator[int]" "typing.List[int]";
  assert_meet "typing.List[float]" "typing.Iterator[int]" "typing.List[$bottom]";
  assert_meet "typing.List[float]" "float[int]" "$bottom";
  assert_meet
    "typing.Dict[str, str]"
    "typing.Dict[str, typing.List[str]]"
    "typing.Dict[str, $bottom]";

  assert_meet ~order:disconnected_order "A" "B" "$bottom";

  (* TypedDictionaries *)
  assert_meet
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int), ('baz', int))]"
    ("mypy_extensions.TypedDict" ^
     "[('$anonymous', True, ('bar', int), ('baz', int), ('ben', int), ('foo', str))]");
  assert_meet
    "mypy_extensions.TypedDict[('Alpha', False, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', False, ('foo', str), ('bar', int), ('baz', int))]"
    ("mypy_extensions.TypedDict" ^
     "[('$anonymous', False, ('bar', int), ('baz', int), ('ben', int), ('foo', str))]");
  assert_meet
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', int))]"
    "$bottom";
  assert_meet
    "mypy_extensions.TypedDict[('Alpha', False, ('bar', int), ('foo', str), ('ben', int))]"
    "mypy_extensions.TypedDict[('Beta', True, ('foo', str), ('bar', int), ('baz', int))]"
    "$bottom";
  assert_meet
    "mypy_extensions.TypedDict[('Alpha', True, ('bar', int), ('foo', str), ('ben', int))]"
    "typing.Mapping[str, typing.Any]"
    "$bottom";

  (* Variables. *)
  assert_type_equal (meet default Type.integer (Type.variable "T")) Type.Bottom;
  assert_type_equal
    (meet
       default
       Type.integer
       (Type.variable ~constraints:(Type.Variable.Bound Type.float) "T"))
    (Type.Bottom);
  assert_type_equal
    (meet
       default
       Type.string
       (Type.variable ~constraints:(Type.Variable.Explicit [Type.float; Type.string]) "T"))
    Type.Bottom;

  (* Undeclared. *)
  assert_type_equal
    (meet default Type.undeclared Type.Bottom)
    (Type.Bottom);
  assert_type_equal
    (meet default Type.Bottom Type.undeclared)
    (Type.Bottom);

  (* Variance. *)
  assert_type_equal
    (meet
       variance_order
       (Type.parametric "LinkedList" [Type.integer])
       (Type.parametric "LinkedList" [Type.Top]))
    (Type.parametric "LinkedList" [Type.integer]);
  assert_type_equal
    (meet
       variance_order
       (Type.parametric "LinkedList" [Type.Top])
       (Type.parametric "LinkedList" [Type.integer]))
    (Type.parametric "LinkedList" [Type.integer]);
  assert_type_equal
    (meet
       variance_order
       (Type.parametric "LinkedList" [Type.integer])
       (Type.parametric "LinkedList" [Type.Any]))
    (Type.parametric "LinkedList" [Type.Bottom]);
  assert_type_equal
    (meet
       variance_order
       (Type.parametric "LinkedList" [Type.Any])
       (Type.parametric "LinkedList" [Type.integer]))
    (Type.parametric "LinkedList" [Type.Bottom]);
  assert_meet
    ~order:variance_order
    "Derived[int]"
    "Base[int]"
    "Derived[int]";
  assert_meet
    ~order:variance_order
    "Derived[float]"
    "Base[float]"
    "Derived[float]";
  assert_meet
    ~order:variance_order
    "Derived[int]"
    "Base[float]"
    "Derived[int]";
  assert_meet
    ~order:variance_order
    "Derived[float]"
    "Base[int]"
    "Derived[float]";
  assert_meet
    ~order:multiplane_variance_order
    "B[int, float]"
    "A[int, float]"
    "B[int, float]";
  assert_meet
    ~order:multiplane_variance_order
    "B[int, int]"
    "A[int, float]"
    "B[int, int]";
  assert_meet
    ~order:multiplane_variance_order
    "B[float, int]"
    "A[int, float]"
    "B[float, int]";
  assert_meet
    ~order:multiplane_variance_order
    "B[float, float]"
    "A[int, float]"
    "B[float, float]";
  assert_meet
    ~order:multiplane_variance_order
    "B[int, float]"
    "A[float, float]"
    "B[int, float]";
  assert_meet
    ~order:multiplane_variance_order
    "B[int, int]"
    "A[float, float]"
    "B[int, int]";
  assert_meet
    ~order:multiplane_variance_order
    "B[float, int]"
    "A[float, float]"
    "B[float, int]";
  assert_meet
    ~order:multiplane_variance_order
    "B[float, float]"
    "A[float, float]"
    "B[float, float]";
  assert_meet
    ~order:parallel_planes_variance_order
    "B[float, float]"
    "A[int, float]"
    "B[int, float]";
  assert_meet
    ~order:parallel_planes_variance_order
    "B[float, float]"
    "A[int, int]"
    "B[int, float]";
  ()


let test_least_upper_bound _ =
  assert_equal (least_upper_bound order Type.Bottom Type.Bottom) [Type.Bottom];

  assert_equal (least_upper_bound order Type.Bottom !"0") [!"0"];
  assert_equal (least_upper_bound order Type.Bottom !"1") [!"1"];
  assert_equal (least_upper_bound order !"3" !"1") [!"3"];
  assert_equal (least_upper_bound order !"4" !"bottom") [!"4"];

  assert_equal (least_upper_bound order !"0" !"1") [!"3"];
  assert_equal (least_upper_bound order !"0" !"2") [Type.Top];
  assert_equal (least_upper_bound order !"0" !"2") [Type.Top];

  assert_equal (least_upper_bound order Type.Top Type.Top) [Type.Top];

  assert_equal (least_upper_bound butterfly !"0" !"1") [!"3"; !"2"]


let test_greatest_lower_bound _ =
  let assert_greatest_lower_bound ~order type1 type2 expected =
    let actual = greatest_lower_bound order type1 type2 |> List.sort ~compare:Type.compare in
    assert_equal
      ~printer:(List.to_string ~f:Type.show)
      actual
      expected
  in
  assert_greatest_lower_bound ~order:diamond_order Type.Bottom Type.Bottom [Type.Bottom];

  assert_greatest_lower_bound ~order:diamond_order Type.Bottom !"D" [Type.Bottom];
  assert_greatest_lower_bound ~order:diamond_order Type.Bottom !"A" [Type.Bottom];
  assert_greatest_lower_bound ~order:diamond_order !"A" !"C" [!"C"];
  assert_greatest_lower_bound ~order:diamond_order !"A" !"B" [!"B"];
  assert_greatest_lower_bound ~order:diamond_order !"A" !"D" [!"D"];
  assert_greatest_lower_bound ~order:diamond_order !"B" !"D" [!"D"];
  assert_greatest_lower_bound ~order:diamond_order !"B" !"C" [!"D"];

  assert_greatest_lower_bound ~order:diamond_order Type.Top !"B" [!"B"];

  assert_greatest_lower_bound ~order:diamond_order Type.Top Type.Top [Type.Top];

  assert_greatest_lower_bound ~order:butterfly !"2" !"3" [!"0"; !"1"]


let test_instantiate_parameters _ =
  let order =
    {
      handler = default;
      constructor = (fun _ -> None);
      implements = (fun ~protocol:_ _ -> TypeOrder.DoesNotImplement);
      any_is_bottom = false;
    }
  in
  assert_equal
    (instantiate_successors_parameters
       order
       ~source:(Type.list Type.string)
       ~target:(!"typing.Iterator"))
    (Some [Type.string]);

  assert_equal
    (instantiate_successors_parameters
       order
       ~source:(Type.dictionary ~key:Type.integer ~value:Type.string)
       ~target:(!"typing.Iterator"))
    (Some [Type.integer]);

  assert_equal
    (instantiate_successors_parameters
       order
       ~source:(Type.string)
       ~target:!"typing.Iterable")
    (Some [Type.string]);

  assert_equal
    (instantiate_successors_parameters
       order
       ~source:(Type.tuple [Type.integer; Type.integer])
       ~target:!"typing.Iterable")
    (Some [Type.integer]);

  assert_equal
    (instantiate_successors_parameters
       order
       ~source:!"AnyIterable"
       ~target:!"typing.Iterable")
    (Some [Type.Any]);
  (* If you're not completely specified, fill all with anys *)
  assert_equal
    (instantiate_successors_parameters
       order
       ~source:!"PartiallySpecifiedDict"
       ~target:!"dict")
    (Some [Type.Any; Type.Any]);
  (* If you're over-specified, fill all with anys *)
  assert_equal
    (instantiate_successors_parameters
       order
       ~source:!"OverSpecifiedDict"
       ~target:!"dict")
    (Some [Type.Any; Type.Any]);
  ()


let test_deduplicate _ =
  let (module Handler: TypeOrder.Handler) =
    let order =
      Builder.create ()
      |> TypeOrder.handler
    in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    connect order ~parameters:[Type.Top; Type.Top] ~predecessor:!"0" ~successor:!"1";
    connect order ~parameters:[Type.Top] ~predecessor:!"0" ~successor:!"1";
    deduplicate order ~annotations:[!"0"; !"1"];
    order
  in
  let index_of annotation =
    Handler.find_unsafe (Handler.indices ()) annotation
  in
  let assert_targets edges from target parameters =
    assert_equal
      ~printer:(List.to_string ~f:Target.show)
      (Handler.find_unsafe edges (index_of !from))
      [{ Target.target = index_of !target; parameters }]
  in
  assert_targets (Handler.edges ()) "0" "1" [Type.Top];
  assert_targets (Handler.backedges ()) "1" "0" [Type.Top]


let test_remove_extra_edges _ =
  (* 0 -> 1 -> 2 -> 3
     |----^         ^
     |--------------^
  *)
  let (module Handler: TypeOrder.Handler) =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    insert order !"2";
    insert order !"3";
    connect order ~predecessor:!"0" ~successor:!"1";
    connect order ~predecessor:!"0" ~successor:!"3";
    connect order ~predecessor:!"1" ~successor:!"2";
    connect order ~predecessor:!"2" ~successor:!"3";
    remove_extra_edges order ~bottom:!"0" ~top:!"3" [!"0"; !"1"; !"2"; !"3"];
    order
  in
  let zero_index = Handler.find_unsafe (Handler.indices ()) !"0" in
  let one_index = Handler.find_unsafe (Handler.indices ()) !"1" in
  let two_index = Handler.find_unsafe (Handler.indices ()) !"2" in
  let three_index = Handler.find_unsafe (Handler.indices ()) !"3" in
  assert_equal
    (Handler.find_unsafe (Handler.edges ()) zero_index)
    [{ Target.target = one_index; parameters = []}];
  assert_equal
    (Handler.find_unsafe (Handler.backedges ()) three_index)
    [{ Target.target = two_index; parameters = []}]


let test_connect_annotations_to_top _ =
  (* Partial partial order:
      0 - 2
      |
      1   3 *)
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    insert order !"2";
    insert order !"3";
    connect order ~predecessor:!"0" ~successor:!"2";
    connect order ~predecessor:!"0" ~successor:!"1";
    connect_annotations_to_top order ~top:!"3" [!"0"; !"1"; !"2"; !"3"];
    order in

  assert_equal
    (least_upper_bound order !"1" !"2")
    [!"3"];

  (* Ensure that the backedge gets added as well *)
  assert_equal
    (greatest_lower_bound order !"1" !"3")
    [!"1"]


let test_backedges _ =
  let (module Handler: TypeOrder.Handler) =
    let order =
      Builder.create ()
      |> TypeOrder.handler
    in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    insert order !"2";
    insert order !"3";
    insert order !"4";
    connect order ~predecessor:!"1" ~successor:!"0";
    connect order ~predecessor:!"4" ~successor:!"0";
    connect order ~predecessor:!"3" ~successor:!"0";
    connect order ~predecessor:!"2" ~successor:!"0";
    order
  in
  let index_of annotation =
    Handler.find_unsafe (Handler.indices ()) annotation
  in
  let assert_targets edges from targets =
    let targets =
      let create target = { Target.target = index_of !target; parameters = [] } in
      List.map targets ~f:create
    in
    let printer targets =
      targets
      |> List.map
        ~f:(fun { Target.target; _ } -> Handler.find_unsafe (Handler.annotations ()) target)
      |> List.map ~f:Type.show
      |> String.concat
    in
    assert_equal
      ~printer
      targets
      (Handler.find_unsafe edges (index_of !from))
  in
  (* After normalization, backedges are ordered by target comparison, not insertion order. *)
  assert_targets (Handler.backedges ()) "0" ["2"; "3"; "4"; "1"];
  TypeOrder.normalize (module Handler);
  assert_targets (Handler.backedges ()) "0" ["3"; "2"; "4"; "1"]


let test_check_integrity _ =
  check_integrity order;
  check_integrity butterfly;

  (* 0 <-> 1 *)
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    connect order ~predecessor:!"0" ~successor:!"1";
    connect order ~predecessor:!"1" ~successor:!"0";
    order in
  assert_raises TypeOrder.Cyclic (fun _ -> check_integrity order);

  (* 0 -> 1
     ^    |
      \   v
     .  - 2 -> 3 *)
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order !"0";
    insert order !"1";
    insert order !"2";
    insert order !"3";
    connect order ~predecessor:!"0" ~successor:!"1";
    connect order ~predecessor:!"1" ~successor:!"2";
    connect order ~predecessor:!"2" ~successor:!"0";
    connect order ~predecessor:!"2" ~successor:!"3";
    order in
  assert_raises TypeOrder.Cyclic (fun _ -> check_integrity order);

  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order !"0";
    order in
  assert_raises TypeOrder.Incomplete (fun _ -> check_integrity order);

  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Top;
    insert order !"0";
    order in
  assert_raises TypeOrder.Incomplete (fun _ -> check_integrity order)


let test_to_dot _ =
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order !"0";
    insert order !"1";
    insert order !"2";
    insert order !"3";
    insert order Type.Bottom;
    insert order Type.Top;
    connect order ~predecessor:!"0" ~successor:!"2";
    connect order ~predecessor:!"0" ~successor:!"1" ~parameters:[Type.string];
    connect_annotations_to_top order ~top:!"3" [!"0"; !"1"; !"2"; !"3"];
    order in
  let (module Handler) = order in
  assert_equal
    ~printer:ident
    ({|
        digraph {
          129913994[label="undefined"]
          360125662[label="0"]
          544641955[label="3"]
          648017920[label="unknown"]
          874630001[label="2"]
          1061160138[label="1"]
          360125662 -> 874630001
          360125662 -> 1061160138[label="(str)"]
          874630001 -> 544641955
          1061160138 -> 544641955
        }
     |}
     |> Test.trim_extra_indentation)
    ("\n" ^ TypeOrder.to_dot order)


let test_normalize _ =
  let assert_normalize ~edges ~expected_edges ~expected_backedges =
    let nodes =
      List.fold
        edges
        ~init:[]
        ~f:(fun edges (predecessor, successor) -> predecessor :: successor :: edges)
      |> Type.Set.of_list
    in
    let ((module Handler: TypeOrder.Handler) as order) = Builder.create () |> TypeOrder.handler in
    Set.iter nodes ~f:(fun node -> insert order node);
    List.iter edges ~f:(fun (predecessor, successor) -> connect order ~predecessor ~successor);
    TypeOrder.normalize order;
    let index annotation = Handler.find_unsafe (Handler.indices ()) annotation in
    let assert_match edges (name, expected) =
      let expected =
        List.map expected ~f:(fun name -> { Target.target = index name; parameters = [] })
      in
      let show_targets targets =
        let show_target { Target.target; _ } =
          Handler.find_unsafe (Handler.annotations ()) target
          |> Type.show
        in
        List.to_string targets ~f:show_target
      in
      assert_equal
        ~printer:show_targets
        ~cmp:(List.equal ~equal:Target.equal)
        expected
        (Handler.find_unsafe edges (index name))
    in
    List.iter expected_edges ~f:(assert_match (Handler.edges ()));
    List.iter expected_backedges ~f:(assert_match (Handler.backedges ()))
  in
  assert_normalize
    ~edges:[!"1", !"2"]
    ~expected_edges:[
      !"2", [];
      !"1", [!"2"];
    ]
    ~expected_backedges:[
      !"2", [!"1"];
      !"1", [];
    ];
  assert_normalize
    ~edges:[!"1", !"2"; !"2", !"3"]
    ~expected_edges:[
      !"1", [!"2"];
      !"2", [!"3"];
      !"3", [];
    ]
    ~expected_backedges:[
      !"3", [!"2"];
      !"2", [!"1"];
      !"1", [];
    ];
  assert_normalize
    ~edges:[!"1", !"3"; !"2", !"3"]
    ~expected_edges:[
      !"1", [!"3"];
      !"2", [!"3"];
      !"3", [];
    ]
    ~expected_backedges:[
      !"3", [!"2"; !"1"];
      !"2", [];
      !"1", [];
    ];
  (* Order doesn't matter. *)
  assert_normalize
    ~edges:[!"2", !"3"; !"1", !"3"]
    ~expected_edges:[
      !"1", [!"3"];
      !"2", [!"3"];
      !"3", [];
    ]
    ~expected_backedges:[
      !"3", [!"2"; !"1"];
      !"2", [];
      !"1", [];
    ];

  assert_normalize
    ~edges:[Type.Bottom, !"A"; Type.Bottom, !"B"; !"other", !"A"; !"other", !"B"]
    ~expected_edges:[
      Type.Bottom, [!"A"; !"B"];
      !"other", [!"B"; !"A"];
    ]
    ~expected_backedges:[
      !"B", [Type.Bottom; !"other"];
      !"A", [Type.Bottom; !"other"];
      Type.Bottom, [];
      !"other", [];
    ];
  assert_normalize
    ~edges:[Type.Bottom, !"B"; Type.Bottom, !"A"; !"other", !"B"; !"other", !"A"]
    ~expected_edges:[
      Type.Bottom, [!"A"; !"B"];
      !"other", [!"A"; !"B"];
    ]
    ~expected_backedges:[
      !"B", [Type.Bottom; !"other"];
      !"A", [Type.Bottom; !"other"];
      Type.Bottom, [];
      !"other", [];
    ]


let test_variables _ =
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order Type.generic;
    insert order !"A";
    insert order !"B";
    connect ~parameters:[Type.variable "T"] order ~predecessor:!"A" ~successor:Type.generic;
    connect order ~predecessor:Type.Bottom ~successor:!"A";
    connect order ~predecessor:Type.Bottom ~successor:!"B";
    connect order ~predecessor:!"B" ~successor:Type.Top;
    connect order ~predecessor:Type.generic ~successor:Type.Top;
    order
  in
  let assert_variables ~expected source =
    let aliases = fun _ -> None in
    let annotation =
      parse_single_expression source
      |> Type.create ~aliases
    in
    assert_equal expected (TypeOrder.variables order annotation)
  in
  assert_variables ~expected:None "B";
  assert_variables ~expected:(Some [Type.variable "T"]) "A";
  assert_variables ~expected:(Some [Type.variable "T"]) "A[int]";
  assert_variables ~expected:None "Nonexistent"


let test_is_instantiated _ =
  let order =
    let order = Builder.create () |> TypeOrder.handler in
    insert order Type.Bottom;
    insert order Type.Top;
    insert order Type.generic;
    insert order !"A";
    insert order !"B";
    connect order ~predecessor:Type.Bottom ~successor:!"A";
    connect order ~predecessor:Type.Bottom ~successor:!"B";
    connect order ~predecessor:!"A" ~successor:Type.Top;
    connect order ~predecessor:!"B" ~successor:Type.Top;
    order
  in
  assert_true (TypeOrder.is_instantiated order (Type.Primitive "A"));
  assert_true (TypeOrder.is_instantiated order (Type.Primitive "B"));
  assert_false (TypeOrder.is_instantiated order (Type.Primitive "C"));
  assert_true (TypeOrder.is_instantiated order (Type.parametric "A" [Type.Primitive "B"]));
  assert_true (TypeOrder.is_instantiated order (Type.parametric "A" [Type.Primitive "A"]));
  assert_true
    (TypeOrder.is_instantiated
       order
       (Type.parametric "A" [Type.Primitive "A"; Type.Primitive "B"]));
  assert_false
    (TypeOrder.is_instantiated
       order
       (Type.parametric "A" [Type.Primitive "C"; Type.Primitive "B"]));
  assert_false
    (TypeOrder.is_instantiated
       order
       (Type.parametric "C" [Type.Primitive "A"; Type.Primitive "B"]))


let test_solve_less_or_equal _ =
  let resolution =
    let configuration = Configuration.Analysis.create () in
    let populate source =
      let environment =
        let environment = Environment.Builder.create () in
        Test.populate
          ~configuration
          (Environment.handler environment)
          (parse source :: typeshed_stubs ());
        environment
      in
      Environment.handler environment
    in
    populate
      {|
      class C: ...
      class D(C): ...
      class Q: ...
      T_Unconstrained = typing.TypeVar('T_Unconstrained')
      T_Bound_C = typing.TypeVar('T_Bound_C', bound=C)
      T_Bound_D = typing.TypeVar('T_Bound_D', bound=D)
      T_Bound_Union = typing.TypeVar('T_Bound_Union', bound=typing.Union[int, str])
      T_Bound_Union_C_Q = typing.TypeVar('T_Bound_Union_C_Q', bound=typing.Union[C, Q])
      T_Bound_Union = typing.TypeVar('T_Bound_Union', bound=typing.Union[int, str])
      T_C_Q = typing.TypeVar('T_C_Q', C, Q)
      T_D_Q = typing.TypeVar('T_D_Q', D, Q)
      T_C_Q_int = typing.TypeVar('T_C_Q_int', C, Q, int)

      T = typing.TypeVar('T')
      T1 = typing.TypeVar('T1')
      T2 = typing.TypeVar('T2')
      T3 = typing.TypeVar('T3')
      T4 = typing.TypeVar('T4')
      class G_invariant(typing.Generic[T]):
        pass
      T_Covariant = typing.TypeVar('T_Cov', covariant=True)
      class G_covariant(typing.Generic[T_Covariant]):
        pass

      class Constructable:
        def Constructable.__init__(self, x: int) -> None:
          pass
    |}
    |> fun environment -> TypeCheck.resolution environment ()
  in
  let handler =
    let constructor instantiated =
      Resolution.class_definition resolution instantiated
      >>| Class.create
      >>| Class.constructor ~instantiated ~resolution
    in
    let implements ~protocol callable =
      match protocol, callable with
      | Type.Parametric { name = "G_invariant"; _ }, Type.Callable _  ->
          TypeOrder.Implements { parameters = [Type.integer] }
      | _ ->
          TypeOrder.DoesNotImplement
    in
    { handler = Resolution.order resolution; constructor; implements; any_is_bottom = false }
  in
  let assert_solve
      ~left
      ~right
      ?constraints
      ?(leave_unbound_in_left = [])
      ?(postprocess = Type.Variable.mark_all_variables_as_bound ~simulated:false)
      ?(replace_escaped_variables_with_any = false)
      expected =
    let parse_annotation annotation =
      annotation
      |> parse_single_expression
      |> Resolution.parse_annotation resolution
    in
    let left =
      let constraints annotation =
        match annotation with
        | Type.Variable { variable = variable_name; _ }
          when not (List.exists leave_unbound_in_left ~f:((=) variable_name)) ->
            Some (Type.Variable.mark_all_variables_as_bound annotation)
        | _ -> None
      in
      parse_annotation left
      |> Type.instantiate ~constraints
    in
    let right = parse_annotation right in
    let expected =
      let parse_pairs =
        List.map
          ~f:(fun (key, value) -> (parse_annotation key, parse_annotation value |> postprocess))
      in
      expected
      |> List.map ~f:parse_pairs
      |> List.map ~f:Type.Map.of_alist_exn
    in
    let constraints =
      let add_bounds sofar (key, (lower_bound, upper_bound)) =
        let variable =
          match parse_annotation key with
          | Type.Variable variable -> variable
          | _ -> failwith "not a variable"
        in
        let unwrap optional =
          Option.value_exn ~message:"given pre-constraints are invalid" optional
        in
        let sofar =
          lower_bound
          >>| parse_annotation
          >>| postprocess
          >>| (fun bound ->
              OrderedConstraints.add_lower_bound sofar ~order:handler ~variable ~bound |> unwrap)
          |> Option.value ~default:sofar
        in
        upper_bound
        >>| parse_annotation
        >>| postprocess
        >>| (fun bound ->
            OrderedConstraints.add_upper_bound sofar ~order:handler ~variable ~bound |> unwrap)
        |> Option.value ~default:sofar
      in
      constraints
      >>| List.fold ~init:TypeConstraints.empty ~f:add_bounds
      |> Option.value ~default:TypeConstraints.empty
    in
    let list_of_maps_compare left right =
      let and_map_equal sofar left right  = sofar && (Type.Map.equal Type.equal left right) in
      match List.fold2 left right ~init:true ~f:and_map_equal with
      | List.Or_unequal_lengths.Ok comparison -> comparison
      | List.Or_unequal_lengths.Unequal_lengths -> false
    in
    let list_of_map_print map =
      let show_line ~key ~data accumulator =
        (Format.sprintf "%s -> %s" (Type.show key) (Type.show data)) :: accumulator
      in
      map
      |> List.map ~f:(Map.fold ~init:[] ~f:show_line)
      |> List.map ~f:(String.concat ~sep:", ")
      |> List.map ~f:(Printf.sprintf "[%s]")
      |> String.concat ~sep:";\n"
      |> Printf.sprintf "{\n%s\n}"
    in
    let replace =
      if replace_escaped_variables_with_any then
        Type.Map.map ~f:Type.Variable.convert_all_escaped_free_variables_to_anys
      else
        Fn.id
    in
    assert_equal
      ~cmp:list_of_maps_compare
      ~printer:list_of_map_print
      expected
      (solve_less_or_equal handler ~constraints ~left ~right
       |> List.filter_map ~f:(OrderedConstraints.solve ~order:handler)
       |> List.map ~f:replace)
  in
  assert_solve ~left:"C" ~right:"T_Unconstrained" [["T_Unconstrained", "C"]];
  assert_solve ~left:"D" ~right:"T_Unconstrained" [["T_Unconstrained", "D"]];
  assert_solve ~left:"Q" ~right:"T_Unconstrained" [["T_Unconstrained", "Q"]];

  assert_solve ~left:"C" ~right:"T_Bound_C" [["T_Bound_C", "C"]];
  assert_solve ~left:"D" ~right:"T_Bound_C" [["T_Bound_C", "D"]];
  assert_solve ~left:"Q" ~right:"T_Bound_C" [];
  assert_solve ~left:"C" ~right:"T_Bound_D" [];

  assert_solve ~left:"C" ~right:"T_C_Q" [["T_C_Q", "C"]];
  (* An explicit type variable can only be bound to its constraints *)
  assert_solve ~left:"D" ~right:"T_C_Q" [["T_C_Q", "C"]];
  assert_solve ~left:"C" ~right:"T_D_Q" [];


  assert_solve
    ~left:"typing.Union[int, G_invariant[str], str]"
    ~right:"T_Unconstrained"
    [["T_Unconstrained", "typing.Union[int, G_invariant[str], str]"]];
  assert_solve ~left:"typing.Union[D, C]" ~right:"T_Bound_C" [["T_Bound_C", "C"]];

  assert_solve
    ~constraints:["T_Unconstrained", (Some "Q", None)]
    ~left:"G_invariant[C]"
    ~right:"G_invariant[T_Unconstrained]"
    [];
  assert_solve
    ~constraints:["T_Unconstrained", (Some "Q", None)]
    ~left:"G_covariant[C]"
    ~right:"G_covariant[T_Unconstrained]"
    [["T_Unconstrained", "typing.Union[Q, C]"]];

  assert_solve
    ~left:"typing.Optional[C]"
    ~right:"typing.Optional[T_Unconstrained]"
    [["T_Unconstrained", "C"]];
  assert_solve
    ~left:"C"
    ~right:"typing.Optional[T_Unconstrained]"
    [["T_Unconstrained", "C"]];

  assert_solve
    ~left:"typing.Tuple[C, ...]"
    ~right:"typing.Tuple[T_Unconstrained, ...]"
    [["T_Unconstrained", "C"]];
  assert_solve
    ~left:"typing.Tuple[C, Q, D]"
    ~right:"typing.Tuple[T_Unconstrained, T_Unconstrained, C]"
    [["T_Unconstrained", "typing.Union[C, Q]"]];
  assert_solve
    ~left:"typing.Tuple[D, ...]"
    ~right:"typing.Tuple[T_Unconstrained, T_Unconstrained, C]"
    [["T_Unconstrained", "D"]];
  assert_solve
    ~left:"typing.Tuple[C, Q, D]"
    ~right:"typing.Tuple[T_Unconstrained, ...]"
    [["T_Unconstrained", "typing.Union[C, Q]"]];

  assert_solve
    ~left:"G_covariant[C]"
    ~right:"typing.Union[G_covariant[T_Unconstrained], int]"
    [["T_Unconstrained", "C"]];

  assert_solve
    ~left:"typing.Type[int]"
    ~right:"typing.Callable[[], T_Unconstrained]"
    (* there are two int constructor overloads *)
    [["T_Unconstrained", "int"]; ["T_Unconstrained", "int"]];

  assert_solve
    ~left:"typing.Optional[typing.Tuple[C, Q, typing.Callable[[D, int], C]]]"
    ~right:"typing.Optional[typing.Tuple[T, T, typing.Callable[[T, T], T]]]"
    [];
  assert_solve
    ~left:"typing.Optional[typing.Tuple[C, C, typing.Callable[[C, C], C]]]"
    ~right:"typing.Optional[typing.Tuple[T, T, typing.Callable[[T, T], T]]]"
    [["T", "C"]];

  (* Bound => Bound *)
  assert_solve
    ~left:"T_Bound_D"
    ~right:"T_Bound_C"
    [["T_Bound_C", "T_Bound_D"]];
  assert_solve
    ~left:"T_Bound_C"
    ~right:"T_Bound_D"
    [];
  assert_solve
    ~left:"T_Bound_Union"
    ~right:"T_Bound_Union"
    [["T_Bound_Union", "T_Bound_Union"]];

  (* Bound => Explicit *)
  assert_solve
    ~left:"T_Bound_D"
    ~right:"T_C_Q"
    [["T_C_Q", "C"]];
  assert_solve
    ~left:"T_Bound_C"
    ~right:"T_D_Q"
    [];

  (* Explicit => Bound *)
  assert_solve
    ~left:"T_D_Q"
    ~right:"T_Bound_Union_C_Q"
    [["T_Bound_Union_C_Q", "T_D_Q"]];
  assert_solve
    ~left:"T_D_Q"
    ~right:"T_Bound_D"
    [];

  (* Explicit => Explicit *)
  assert_solve
    ~left:"T_C_Q"
    ~right:"T_C_Q_int"
    [["T_C_Q_int", "T_C_Q"]];
  (* This one is theoretically solvable, but only if we're willing to introduce dependent variables
     as the only sound solution here would be
     T_C_Q_int => T_new <: C if T_D_Q is D, Q if T_D_Q is Q *)
  assert_solve
    ~left:"T_D_Q"
    ~right:"T_C_Q_int"
    [];

  assert_solve
    ~leave_unbound_in_left:["T_Unconstrained"]
    ~left:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
    ~right:"typing.Callable[[int], int]"
    [[]];
  assert_solve
    ~left:"typing.Callable[[int], int]"
    ~right:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
    [["T_Unconstrained", "int"]];
  assert_solve
    ~leave_unbound_in_left:["T"]
    ~replace_escaped_variables_with_any:true
    ~left:"typing.Callable[[Named(a, T, default)], G_invariant[T]]"
    ~right:"typing.Callable[[], T_Unconstrained]"
    [["T_Unconstrained", "G_invariant[typing.Any]"]];
  assert_solve
    ~leave_unbound_in_left:["T"]
    ~left:"typing.Callable[[T], T]"
    ~right:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
    [[]];
  assert_solve
    ~leave_unbound_in_left:["T"]
    ~left:"typing.Callable[[T], G_invariant[T]]"
    ~right:"typing.Callable[[T_Unconstrained], T_Unconstrained]"
    [];
  assert_solve
    ~leave_unbound_in_left:["T1"]
    ~left:"typing.Callable[[T1], typing.Tuple[T1, T2]]"
    ~right:"typing.Callable[[T3], typing.Tuple[T3, T4]]"
    [["T4", "T2"]];
  assert_solve
    ~left:"typing.Type[Constructable]"
    ~right:"typing.Callable[[T3], T4]"
    [["T3", "int"; "T4", "Constructable"]];
  assert_solve
    ~left:"typing.Callable[[typing.Union[int, str]], str]"
    ~right:"typing.Callable[[int], T4]"
    [["T4", "str"]];
  assert_solve
    ~left:"typing.Callable[[typing.Union[int, str], int], str]"
    ~right:"typing.Callable[[int, T3], T4]"
    [["T3", "int"; "T4", "str"]];

  (* Callback protocols *)
  assert_solve
    ~left:"typing.Callable[[int], str]"
    ~right:"G_invariant[T1]"
    [["T1", "int"]];

  (* Multiple options *)
  assert_solve
    ~left:"typing.List[int]"
    ~right:"typing.Union[typing.List[T1], T1]"
    [["T1", "int"]; ["T1", "typing.List[int]"]];
  assert_solve
    ~left:"typing.Tuple[typing.List[int], typing.List[int]]"
    ~right:"typing.Tuple[typing.Union[typing.List[T1], T1], T1]"
    [["T1", "typing.List[int]"]];
  assert_solve
    ~left:"typing.Tuple[typing.List[int], typing.List[int]]"
    ~right:"typing.Tuple[typing.Union[typing.List[T1], T1], T1]"
    [["T1", "typing.List[int]"]];
  assert_solve
    ~left:(
      "typing.Callable[[typing.Union[int, str]], typing.Union[int, str]]" ^
      "[[[int], str][[str], int]]")
    ~right:"typing.Callable[[T3], T4]"
    [
      ["T3", "int"; "T4", "str"];
      ["T3", "str"; "T4", "int"];
      ["T3", "typing.Union[int, str]"; "T4", "typing.Union[int, str]"];
    ];

  (* Free Variable <-> Free Variable constraints *)
  assert_solve
    ~postprocess:Fn.id
    ~leave_unbound_in_left:["T1"]
    ~left:"T1"
    ~right:"T2"
    [["T2", "T1"]; ["T1", "T2"]];
  assert_solve
    ~postprocess:Fn.id
    ~leave_unbound_in_left:["T"]
    ~left:"typing.Callable[[T], T]"
    ~right:"typing.Callable[[T1], T2]"
    [["T2", "T1"]; ["T1", "T2"]];
  assert_solve
    ~leave_unbound_in_left:["T"]
    ~left:"typing.Tuple[typing.Callable[[T], T], int]"
    ~right:"typing.Tuple[typing.Callable[[T1], T2], T1]"
    [["T2", "int"; "T1", "int"]];
  ()


let test_is_consistent_with _ =
  let is_consistent_with =
    let order =
      {
        handler = default;
        constructor = (fun _ -> None);
        implements = (fun ~protocol:_ _ -> TypeOrder.DoesNotImplement);
        any_is_bottom = false;
      }
    in
    is_consistent_with order
  in
  assert_true (is_consistent_with Type.Bottom Type.Top);
  assert_false (is_consistent_with Type.integer Type.string);

  assert_true (is_consistent_with Type.Any Type.string);
  assert_true (is_consistent_with Type.integer Type.Any);

  assert_false (is_consistent_with (Type.Optional Type.integer) (Type.Optional Type.string));
  assert_true (is_consistent_with (Type.Optional Type.Any) (Type.Optional Type.string));

  assert_false (is_consistent_with (Type.list Type.integer) (Type.list Type.string));
  assert_true (is_consistent_with (Type.list Type.Any) (Type.list Type.string));
  assert_false
    (is_consistent_with
       (Type.dictionary ~key:Type.string ~value:Type.integer)
       (Type.dictionary ~key:Type.string ~value:Type.string));
  assert_true
    (is_consistent_with
       (Type.dictionary ~key:Type.string ~value:Type.Any)
       (Type.dictionary ~key:Type.string ~value:Type.string));
  assert_true
    (is_consistent_with
       (Type.dictionary ~key:Type.Any ~value:Type.Any)
       (Type.dictionary ~key:Type.string ~value:(Type.list Type.integer)));
  assert_true
    (is_consistent_with
       (Type.dictionary ~key:Type.Any ~value:Type.Any)
       (Type.dictionary
          ~key:Type.string
          ~value:(Type.dictionary ~key:Type.string ~value:Type.integer)));
  assert_true
    (is_consistent_with
       (Type.dictionary ~key:Type.Any ~value:Type.Any)
       (Type.Optional
          (Type.dictionary
             ~key:Type.string
             ~value:Type.string)));
  assert_true
    (is_consistent_with
       (Type.dictionary ~key:Type.Any ~value:Type.bool)
       (Type.parametric "typing.Mapping" [Type.integer; Type.bool]));

  assert_false
    (is_consistent_with
       (Type.dictionary ~key:Type.Any ~value:Type.bool)
       (Type.parametric "collections.OrderedDict" [Type.integer; Type.bool]));

  assert_false
    (is_consistent_with
       (Type.dictionary ~key:Type.integer ~value:Type.bool)
       (Type.parametric "collections.OrderedDict" [Type.Any; Type.bool]));

  assert_true
    (is_consistent_with
       (Type.parametric "collections.OrderedDict" [Type.integer; Type.bool])
       (Type.dictionary ~key:Type.Any ~value:Type.bool));

  assert_true
    (is_consistent_with
       (Type.parametric "collections.OrderedDict" [Type.Any; Type.bool])
       (Type.dictionary ~key:Type.integer ~value:Type.bool));

  assert_true
    (is_consistent_with
       (Type.list Type.Any)
       (Type.iterable Type.string));

  assert_true
    (is_consistent_with
       (Type.list Type.integer)
       (Type.sequence Type.Any));

  assert_true
    (is_consistent_with
       (Type.iterable Type.string)
       (Type.Optional Type.Any));

  assert_false
    (is_consistent_with
       (Type.iterable Type.string)
       (Type.Optional Type.string));

  assert_false
    (is_consistent_with
       (Type.iterable Type.string)
       (Type.list Type.Any));
  assert_false
    (is_consistent_with
       (Type.iterable Type.Any)
       (Type.list Type.string));
  assert_false
    (is_consistent_with
       (Type.iterable Type.integer)
       (Type.set Type.Any));
  assert_false
    (is_consistent_with
       (Type.parametric "typing.AbstractSet" [Type.object_primitive])
       (Type.set Type.Any));
  assert_true
    (is_consistent_with
       (Type.set Type.Any)
       (Type.parametric "typing.AbstractSet" [Type.object_primitive]));

  assert_false
    (is_consistent_with
       (Type.tuple [Type.string; Type.string])
       (Type.tuple [Type.string; Type.integer]));
  assert_true
    (is_consistent_with
       (Type.tuple [Type.string; Type.string])
       (Type.tuple [Type.string; Type.Any]));
  assert_false
    (is_consistent_with
       (Type.Tuple (Type.Unbounded Type.integer))
       (Type.Tuple (Type.Unbounded Type.string)));
  assert_true
    (is_consistent_with
       (Type.Tuple (Type.Unbounded Type.integer))
       (Type.Tuple (Type.Unbounded Type.Any)));
  assert_true
    (is_consistent_with
       (Type.Tuple (Type.Bounded [Type.integer; Type.Any]))
       (Type.Tuple (Type.Unbounded Type.integer)));
  assert_true
    (is_consistent_with
       (Type.Tuple (Type.Bounded [Type.integer; Type.string]))
       (Type.Tuple (Type.Unbounded Type.Any)));
  assert_false
    (is_consistent_with
       (Type.Tuple (Type.Bounded [Type.integer; Type.string]))
       (Type.Tuple (Type.Unbounded Type.string)));

  assert_false
    (is_consistent_with
       (Type.union [Type.integer; Type.string])
       (Type.union [Type.integer; Type.float]));
  assert_true
    (is_consistent_with
       (Type.union [Type.integer; Type.string])
       (Type.union [Type.integer; Type.Any]));

  assert_true
    (is_consistent_with
       (Type.union [Type.integer; Type.Any])
       Type.integer);


  assert_false (is_consistent_with (Type.iterator Type.integer) (Type.generator Type.Any));
  assert_true (is_consistent_with (Type.generator Type.Any) (Type.iterator Type.integer));
  assert_false
    (is_consistent_with
       (Type.iterator (Type.list Type.integer))
       (Type.generator (Type.list Type.Any)));
  assert_true
    (is_consistent_with
       (Type.generator (Type.list Type.Any))
       (Type.iterator (Type.list Type.integer)));
  assert_false (is_consistent_with (Type.iterator Type.integer) (Type.generator Type.float));

  assert_false
    (is_consistent_with
       (Type.Union [Type.list Type.integer; Type.string])
       (Type.list Type.Any));

  assert_true
    (is_consistent_with
       (Type.Callable.create ~annotation:Type.integer ())
       Type.Any);
  assert_true
    (is_consistent_with
       Type.Any
       (Type.Callable.create ~annotation:Type.integer ()));
  assert_true
    (is_consistent_with
       Type.Any
       (Type.union [Type.integer; Type.Callable.create ~annotation:Type.integer ()]));

  assert_true
    (is_consistent_with
       (parse_callable "typing.Callable[[typing.Any], int]")
       (parse_callable "typing.Callable[[str], int]"));
  assert_true
    (is_consistent_with
       (parse_callable "typing.Callable[[int], typing.Any]")
       (parse_callable "typing.Callable[[int], int]"));
  assert_false
    (is_consistent_with
       (parse_callable "typing.Callable[[int], typing.Any]")
       (parse_callable "typing.Callable[[str], int]"));
  assert_false
    (is_consistent_with
       (parse_callable "typing.Callable[[typing.Any, typing.Any], typing.Any]")
       (parse_callable "typing.Callable[[typing.Any], typing.Any]"))


let () =
  "order">:::[
    "backedges">::test_backedges;
    "check_integrity">::test_check_integrity;
    "connect_annotations_to_top">::test_connect_annotations_to_top;
    "deduplicate">::test_deduplicate;
    "default">::test_default;
    "greatest_lower_bound">::test_greatest_lower_bound;
    "instantiate_parameters">::test_instantiate_parameters;
    "is_instantiated">::test_is_instantiated;
    "join">::test_join;
    "least_upper_bound">::test_least_upper_bound;
    "less_or_equal">::test_less_or_equal;
    "less_or_equal_variance">::test_less_or_equal_variance;
    "is_compatible_with">::test_is_compatible_with;
    "meet">::test_meet;
    "method_resolution_order_linearize">::test_method_resolution_order_linearize;
    "remove_extra_edges">::test_remove_extra_edges;
    "successors">::test_successors;
    "to_dot">::test_to_dot;
    "normalize">::test_normalize;
    "variables">::test_variables;
    "solve_less_or_equal">::test_solve_less_or_equal;
    "is_consistent_with">::test_is_consistent_with;
  ]
  |> Test.run
