(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Ast
open Analysis
open Expression
open Statement
open Pyre

open Test
open AnnotatedTest

module Class = Annotated.Class
module Attribute = Annotated.Attribute
module Method = Annotated.Method
module Argument = Call.Argument


let test_generics _ =
  let assert_generics source generics =
    match parse_last_statement source with
    | { Node.value = Statement.Class definition; _ } ->
        let resolution =
          populate source
          |> fun environment -> TypeCheck.resolution environment ()
        in
        let printer generics =
          List.map generics ~f:Type.show
          |> String.concat ~sep:", "
        in
        assert_equal
          ~printer
          ~cmp:(List.equal ~equal:Type.equal)
          (Class.create (Node.create_with_default_location definition)
           |> Class.generics ~resolution)
          generics
    | _ ->
        assert_unreached ()
  in
  assert_generics "class Foo(): pass" [];
  assert_generics
    {|
      _T = typing.TypeVar('_T')
      class Foo(typing.Generic[_T]): pass
    |}
    [Type.variable "_T"];
  assert_generics
    {|
      _T = typing.TypeVar('_T')
      _S = typing.TypeVar('_S')
      class Foo(typing.Generic[_T, _S]): pass
    |}
    [Type.variable "_T"; Type.variable "_S"];

  assert_generics
    {|
      _T = typing.TypeVar('_T')
      class Foo(typing.Protocol[_T]): pass
    |}
    [Type.variable "_T"];

  assert_generics
    {|
      _T = typing.TypeVar('_T')
      class Foo(typing.Iterable[_T]): pass
    |}
    [Type.variable "_T"];

  assert_generics
    {|
      _T1 = typing.TypeVar('_T1')
      _T2 = typing.TypeVar('_T2')
      class Foo(typing.Dict[_T1, _T2]): pass
    |}
    [Type.variable "_T1"; Type.variable "_T2"];

  assert_generics
    {|
      _T1 = typing.TypeVar('_T1')
      _T2 = typing.TypeVar('_T2')
      class Foo(typing.Iterable[_T1], typing.AsyncIterable[_T2]): pass
    |}
    [Type.variable "_T1"; Type.variable "_T2"];

  assert_generics
    {|
      _T1 = typing.TypeVar('_T1')
      class Foo(typing.Dict[_T1, _T1]): pass
    |}
    [Type.variable "_T1"];
  ()


let test_superclasses _ =
  let environment =
    populate {|
      class object: pass
      class Foo: pass
      class Bar: pass
      class SubFoo(Foo): pass
      class SubFooBar(Foo, Bar): pass
      class SubRecurse(SubFooBar): pass
      class SubRedundant(Foo, SubFooBar): pass
    |} in
  let (!) name =
    {
      Statement.Class.name = !&name;
      bases = [];
      body = [+Pass];
      decorators = [];
      docstring = None;
    }
    |> Node.create_with_default_location
    |> Class.create
  in
  let resolution = TypeCheck.resolution environment () in
  let assert_successors target expected =
    let actual = Class.successors ~resolution target in
    assert_equal
      ~printer:(List.fold ~init:"" ~f:(fun sofar next -> sofar ^ (Type.show_primitive next) ^ " "))
      ~cmp:(List.equal ~equal:Type.equal_primitive)
      expected
      actual
  in
  let assert_superclasses target expected =
    let actual = Class.superclasses ~resolution target in
    let equal left right = Reference.equal (Class.name left) (Class.name right) in
    assert_equal
      ~printer:(fun classes -> Format.asprintf "%a" Sexp.pp [%message (classes: Class.t list)])
      ~cmp:(List.equal ~equal) expected actual
  in

  assert_successors !"Foo" ["object"];
  assert_successors
    !"SubRedundant"
    [
      "SubFooBar";
      "Foo";
      "Bar";
      "object";
    ];
  assert_superclasses !"Foo" [!"object"];
  assert_superclasses !"SubFoo" [!"Foo"; !"object"];
  assert_superclasses !"SubFooBar" [!"Foo"; !"Bar"; !"object"];
  assert_superclasses !"SubRecurse" [!"SubFooBar"; !"Foo"; !"Bar"; !"object"];
  assert_superclasses !"SubRedundant" [!"SubFooBar"; !"Foo"; !"Bar"; !"object"]


type constructor = {
  parameters: (Expression.t Parameter.t) list;
  annotation: Type.t option;
}


let test_get_decorator _ =
  let assert_get_decorator source decorator expected =
    let assert_logic ~convert expected =
      match parse_last_statement ~convert source with
      | { Node.value = Statement.Class definition; _ } ->
          let actual =
            Node.create_with_default_location definition
            |> Class.create
            |> Class.get_decorator ~decorator
          in
          assert_equal ~cmp:(List.equal ~equal:Class.equal_decorator) expected actual
      | _ ->
          assert_true (List.is_empty expected)
    in
    let old_access_expected =
      let to_old ({ Class.arguments; _ } as decorator) =
        let arguments =
          arguments
          >>| List.map
            ~f:(fun { Argument.name; value } ->
              { Argument.name; value = Expression.convert value })
        in
        { decorator with Class.arguments }
      in
      List.map ~f:to_old expected
    in
    assert_logic ~convert:true old_access_expected;
    assert_logic ~convert:false expected;
  in
  assert_get_decorator "class A: pass" "decorator" [];
  assert_get_decorator
    {|
      @decorator
      class A:
        pass
    |}
    "decorator"
    [{ name = "decorator"; arguments = None }];
  assert_get_decorator
    {|
      @decorator.a.b
      class A:
        pass
    |}
    "decorator.a"
    [];
  assert_get_decorator
    {|
      @decorator
      class A:
        pass
    |}
    "decorator.a"
    [];
  assert_get_decorator
    {|
      @decorator.a.b
      class A:
        pass
    |}
    "decorator.a.b"
    [{ name = "decorator.a.b"; arguments = None }];
  assert_get_decorator
    {|
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator.a.b"
    [];
  assert_get_decorator
    {|
      @other.decorator
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator"
    [
      {
        name = "decorator";
        arguments = Some [
            { Argument.name = Some ~+"a"; value = +Name (Name.Identifier "b")};
            { Argument.name = Some ~+"c"; value = +Name (Name.Identifier "d")}
          ];
      };
    ];
  assert_get_decorator
    {|
      @decorator(a=b)
      @decorator(a=b, c=d)
      class A:
        pass
    |}
    "decorator"
    [
      {
        name = "decorator";
        arguments = Some [
            { Argument.name = Some ~+"a"; value = +Name (Name.Identifier "b")};
          ];
      };
      {
        name = "decorator";
        arguments = Some [
            { Argument.name = Some ~+"a"; value = +Name (Name.Identifier "b")};
            { Argument.name = Some ~+"c"; value = +Name (Name.Identifier "d")}
          ];
      };
    ]


let test_constructors _ =
  let assert_constructor source instantiated constructors =
    Class.Attribute.Cache.clear ();
    let resolution =
      populate source
      |> fun environment -> TypeCheck.resolution environment ()
    in
    let instantiated =
      parse_single_expression instantiated
      |> Resolution.parse_annotation ~allow_invalid_type_parameters:true resolution
    in
    match parse_last_statement source with
    | { Node.value = Statement.Class definition; _ } ->
        let callable =
          constructors
          >>| (fun constructors ->
              Resolution.parse_annotation resolution
              (parse_single_expression constructors))
          |> Option.value ~default:Type.Top
        in
        let actual =
          Node.create_with_default_location definition
          |> Class.create
          |> Class.constructor ~resolution ~instantiated
        in
        assert_equal ~printer:Type.show ~cmp:Type.equal callable actual
    | _ ->
        assert_unreached ()
  in
  (* Undefined constructors. *)
  assert_constructor
    "class Foo: pass"
    "Foo"
    (Some "typing.Callable('object.__init__')[[], Foo]");

  assert_constructor
    "class Foo: ..."
    "Foo"
    (Some "typing.Callable('object.__init__')[[], Foo]");

  (* Statement.Defined constructors. *)
  assert_constructor
    {|
      class Foo:
        def Foo.__init__(self, a: int) -> None: pass
    |}
    "Foo"
    (Some "typing.Callable('Foo.__init__')[[Named(a, int)], Foo]");

  assert_constructor
    {|
      class Foo:
        def Foo.__init__(self, a: int) -> None: pass
        @typing.overload
        def Foo.__init__(self, b: str) -> None: pass
    |}
    "Foo"
    (Some
       ("typing.Callable('Foo.__init__')[[Named(a, int)], Foo]" ^
        "[[[Named(b, str)], Foo]]"));

  (* Generic classes. *)
  assert_constructor
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        def Foo.__init__(self) -> None: pass
    |}
    "Foo"
    (Some "typing.Callable('Foo.__init__')[[], Foo[typing.TypeVar('_K'),typing.TypeVar('_V')]]");
  assert_constructor
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        def Foo.__init__(self, x:_K, y:_V) -> None: pass
    |}
    "Foo[int, str]"
    (Some "typing.Callable('Foo.__init__')[[Named(x, int), Named(y, str)], Foo[int, str]]");

  (* Tuples. *)
  assert_constructor
    {|
      _T = typing.TypeVar('_T')
      class tuple(typing.Generic[_T]):
        def tuple.__init__(self) -> None: ...
    |}
    "tuple"
    (Some "typing.Callable('tuple.__init__')[[], typing.Tuple[typing.TypeVar('_T'), ...]]");

  (* Constructors, both __init__ and __new__, are inherited from parents. *)
  assert_constructor
    {|
      class Parent:
        def Parent.__init__(self, x: int) -> None:
          pass
      class C(Parent):
        pass
    |}
    "C"
    (Some "typing.Callable('Parent.__init__')[[Named(x, int)], C]");
  assert_constructor
    {|
      class Parent:
        def Parent.__new__(self, x: str) -> None:
          pass
      class C(Parent):
        pass
    |}
    "C"
    (Some "typing.Callable('Parent.__new__')[[Named(x, str)], C]");
  assert_constructor
    {|
      T = typing.TypeVar('T', bound=C)
      class C:
        def C.__init__(self, x: int) -> None: pass
    |}
    "T"
    (Some "typing.Callable('C.__init__')[[Named(x, int)], T]");
  ()


let test_methods _ =
  let assert_methods source methods =
    match parse_last_statement source with
    | { Node.value = Statement.Class definition; _ } ->
        let actuals =
          let method_name { Define.signature = { name; _ }; _ } = Reference.last name in
          Node.create_with_default_location definition
          |> Class.create
          |> Class.methods
          |> List.map ~f:(fun definition -> Method.define definition |> method_name)
        in
        assert_equal methods actuals
    | _ ->
        assert_unreached ()
  in
  assert_methods "class A: pass" [];
  assert_methods
    {|
      class A:
        def A.foo(): pass
        def A.bar(): pass
        1 + 1
        def A.baz(): ...
    |}
    ["foo"; "bar"; "baz"]


let test_has_method _ =
  let get_actual source target_method =
    let resolution =
      populate source
      |> fun environment -> TypeCheck.resolution environment ()
    in
    match parse_last_statement source with
    | { Node.value = Statement.Class definition; _ } ->
        let actual =
          Node.create_with_default_location definition
          |> Class.create
          |> Class.has_method ~resolution ~name:target_method
        in
        actual
    | _ ->
        false
  in
  let assert_has_method source target_method =
    assert_true (get_actual source target_method)
  in
  let assert_not_has_method source target_method =
    assert_false (get_actual source target_method)
  in
  assert_not_has_method "class A: pass" "foo";
  assert_has_method
    {|
      class A:
        def A.foo(): pass
        def A.bar(): pass
        1 + 1
        def A.baz(): ...
    |}
    "foo";
  assert_has_method
    {|
      class A:
        def A.foo(): pass
        def A.bar(): pass
        1 + 1
        def A.baz(): ...
    |}
    "baz"


let test_is_protocol _ =
  let assert_is_protocol bases expected =
    let is_protocol bases =
      {
        Statement.Class.name = !&"Derp";
        bases;
        body = [];
        decorators = [];
        docstring = None;
      }
      |> Node.create_with_default_location
      |> Class.create
      |> Class.is_protocol
    in
    let old_access_bases =
      List.map
        ~f:(fun { Argument.name; value } ->
            { Argument.name; value = Expression.convert value })
        bases
    in
    assert_equal expected (is_protocol bases);
    assert_equal expected (is_protocol old_access_bases);
  in
  let parse = parse_single_expression in

  assert_is_protocol [] false;
  assert_is_protocol [{ Argument.name = None; value = parse "derp" }] false;
  assert_is_protocol [{ Argument.name = None; value = parse "typing.Protocol" }] true;
  assert_is_protocol [{ Argument.name = None; value = parse "typing_extensions.Protocol" }] true;
  assert_is_protocol [{ Argument.name = Some ~+"metaclass"; value = parse "abc.ABCMeta" }] false;
  assert_is_protocol [{ Argument.name = None; value = parse "typing.Protocol[T]" }] true;
  ()

let test_implements _ =
  (* TODO(T36516076) Adapt assert_conforms to fit testing idioms *)
  let assert_conforms definition protocol conforms =
    let get_last_statement { Source.statements; _ } =
      List.last_exn statements
    in
    let environment = Environment.Builder.create () in
    let definition =
      definition
      |> parse
      |> Preprocessing.preprocess
    in
    let protocol =
      protocol
      |> parse
      |> Preprocessing.preprocess
    in
    Test.populate
      ~configuration
      (Environment.handler environment)
      (definition :: protocol :: Test.typeshed_stubs ());
    let ((module Handler: Environment.Handler) as handler) =
      Environment.handler environment
    in
    let resolution = TypeCheck.resolution handler () in
    Annotated.Class.Attribute.Cache.clear ();
    match get_last_statement definition,
          get_last_statement protocol with
    | { Node.value = Statement.Class definition; _ },
      { Node.value = Statement.Class protocol; _ } ->
        assert_equal
          ~printer:(function
              | TypeOrder.Implements { parameters } ->
                  List.map parameters ~f:Type.show |> String.concat ~sep:","
              | DoesNotImplement ->
                  "None"
            )
          conforms
          (Class.implements
             ~resolution
             ~protocol:(Class.create (Node.create_with_default_location protocol))
             (Class.create (Node.create_with_default_location definition)))
    | _ ->
        assert_unreached ()
  in
  let no_parameters = TypeOrder.Implements { parameters = [] } in

  assert_conforms "class A: pass" "class Protocol: pass" no_parameters;
  assert_conforms
    {|
      class A:
        def foo(): pass
    |}
    {|
      class Protocol:
        def foo(): pass
    |}
    no_parameters;
  assert_conforms
    {|
      class A:
        def foo(): pass
    |}
    {|
      class Protocol:
        def bar(): pass
    |}
    DoesNotImplement;
  assert_conforms
    {|
      class A:
        def foo(): pass
    |}
    {|
      class Protocol:
        def foo(): pass
        def bar(): pass
    |}
    DoesNotImplement;
  assert_conforms
    {|
      class A:
        def foo(): pass
        def bar(): pass
        def baz(): pass
    |}
    {|
      class Protocol:
        def foo(): pass
        def bar(): pass
    |}
    no_parameters;
  assert_conforms
    {|
      class A:
        def bar(): pass
        def foo(): pass
    |}
    {|
      class Protocol:
        def foo(): pass
        def bar(): pass
    |}
    no_parameters;
  assert_conforms
    {|
      class List():
        def empty() -> bool: pass
        def length() -> int: pass
    |}
    {|
      class Sized(typing.Protocol):
        def empty() -> bool: pass
        def len() -> int: pass
    |}
    DoesNotImplement;
  (* Not sure whats meant to happen here... *)
  assert_conforms
    {|
      class List():
        def empty() -> bool: pass
        @typing.overload
        def length(x: int) -> int: pass
        @typing.overload
        def length() -> int: pass
        @typing.overload
        def length(x: int) -> str: pass
        @typing.overload
        def length() -> str: pass
    |}
    {|
      class Sized(typing.Protocol):
        def empty() -> bool: pass
        def length() -> int: pass
    |}
    no_parameters;
  assert_conforms
    {|
      class List():
        def empty() -> bool: pass
        @typing.overload
        def length(x: int) -> str: pass
        @typing.overload
        def length(x: int) -> int: pass
        @typing.overload
        def length() -> str: pass
    |}
    {|
      class Sized(typing.Protocol):
        def empty() -> bool: pass
        def length() -> int: pass
    |}
    no_parameters;
  assert_conforms
    {|
      class A():
        def foo() -> int:
          pass
    |}
    {|
      class P(typing.Protocol):
        def foo() -> float:
          pass
    |}
    no_parameters;
  assert_conforms
    {|
      class FooBarClass():
        def foo(self) -> int:
          return 7
        def bar(self) -> int:
          return 7
    |}
    {|
      class FooProtocol(typing.Protocol):
        def foo(self) -> int: ...

      class BarProtocol(typing.Protocol):
        def bar(self) -> int: ...

      class FooBarProtocol(typing.Protocol, FooProtocol, BarProtocol):
        pass
    |}
    no_parameters;
  assert_conforms
    {|
      class FooClass():
        def foo(self) -> int:
          return 7
    |}
    {|
      class FooProtocol(typing.Protocol):
        def foo(self) -> int: ...

      class BarProtocol(typing.Protocol):
        def bar(self) -> int: ...

      class FooBarProtocol(typing.Protocol, FooProtocol, BarProtocol):
        pass
    |}
    DoesNotImplement;
  assert_conforms
    {|
      _T = TypeVar('_T')
      class list(typing.Generic[_T]):
        def __len__(self) -> int: ...
    |}
    {|
      class Size(typing.Protocol):
        def __len__(self) -> int: ...
    |}
    no_parameters;
  (* TODO(T40727281): No reason for AnnotatedClass.implements to do this if we're only checking
     based on methods_to_implementing_classes *)
  assert_conforms
    {|
      class A:
          def foo(self) -> int: ...

      class B(A):
          def bar(self) -> int: ...
    |}
    {|
      class P(typing.Protocol):
        def foo(self) -> int: ...
    |}
    DoesNotImplement;
  assert_conforms
    {|
    T = typing.TypeVar("T", bound=typing.Union[int, str])
    class A(typing.Generic[T]):
      x: T
      def __init__(self, x: T) -> None:
        self.x = x
      def foo(self) -> T:
        return self.x
    |}
    {|
    T1 = typing.TypeVar("T1")
    class P(typing.Protocol[T1]):
      def foo() -> T1: ...
    |}
    (Implements {
        parameters =
          [Type.variable "T"
             ~constraints:(Type.Variable.Bound (Type.union [Type.integer; Type.string]))]
      });

  assert_conforms
    {|
      T = typing.TypeVar("T", int, str)
      class A(typing.Generic[T]):
        def foo() -> T:
          pass
    |}
    {|
      class P(typing.Protocol):
        def foo() -> typing.Union[int, str]:
          pass
    |}
    no_parameters;
  assert_conforms
    {|
      T = typing.TypeVar("T", int, bool)
      class A(typing.Generic[T]):
        def foo() -> T:
          pass
    |}
    {|
      class P(typing.Protocol):
        def foo() -> typing.Union[int, str]:
          pass
    |}
    DoesNotImplement;
  assert_conforms
    {|
      T = typing.TypeVar("T", bound=typing.Union[int, str])
      class A(typing.Generic[T]):
        def foo() -> T:
          pass
    |}
    {|
      class P(typing.Protocol):
        def foo() -> typing.Union[int, str]:
          pass
    |}
    no_parameters;
  assert_conforms
    {|
      class A():
        def foo() -> int:
          pass
    |}
    {|
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo() -> T:
          pass
    |}
    (Implements { parameters =  [Type.integer] });
  assert_conforms
    {|
      class A():
        def foo() -> bool:
          pass
    |}
    {|
      T = typing.TypeVar("T", int, str)
      class P(typing.Protocol[T]):
        def foo() -> T:
          pass
    |}
    DoesNotImplement;
  assert_conforms
    {|
      class A:
        foo: int = 7
    |}
    {|
      class Protocol:
        foo: int = ...
    |}
    no_parameters;
  ()


let test_callable_implements _ =
  let assert_conforms callable protocol conforms =
    let get_last_statement { Source.statements; _ } =
      List.last_exn statements
    in
    let environment = Environment.Builder.create () in
    let callable =
      match parse_callable callable with
      | Type.Callable callable -> callable
      | _ -> failwith "Failed to parse callable."
    in
    let protocol =
      protocol
      |> parse
      |> Preprocessing.preprocess
    in
    Test.populate
      ~configuration
      (Environment.handler environment)
      (protocol :: Test.typeshed_stubs ());
    let ((module Handler: Environment.Handler) as handler) =
      Environment.handler environment
    in
    let resolution = TypeCheck.resolution handler () in
    Annotated.Class.Attribute.Cache.clear ();
    match get_last_statement protocol with
    | { Node.value = Statement.Class protocol; _ } ->
        assert_equal
          ~printer:(function
              | TypeOrder.Implements { parameters } ->
                  List.map parameters ~f:Type.show |> String.concat ~sep:","
              | DoesNotImplement ->
                  "None"
            )
          conforms
          (Class.callable_implements
             ~resolution
             ~protocol:(Class.create (Node.create_with_default_location protocol))
             callable)
    | _ ->
        assert_unreached ()
  in
  let no_parameters = TypeOrder.Implements { parameters = [] } in
  assert_conforms
    "typing.Callable[[], str]"
    {|
      class P(typing.Protocol):
        def __call__(self) -> str: ...
    |}
    no_parameters;
  assert_conforms
    "typing.Callable[[Named(x, int)], str]"
    {|
      class P(typing.Protocol):
        def __call__(self, x: int) -> str: ...
    |}
    no_parameters;
  assert_conforms
    "typing.Callable[[int], str]"
    {|
      class P(typing.Protocol):
        def __call__(self, x: int) -> str: ...
    |}
    DoesNotImplement;
  assert_conforms
    "typing.Callable[[], str]"
    {|
      class P(typing.Protocol):
        def other(self) -> str: ...
        def __call__(self) -> str: ...
    |}
    no_parameters;
  (* TODO(T41448661): support this syntax *)
  assert_conforms
    "typing.Callable[[int], str]"
    {|
      class P(typing.Protocol):
        def __call__(self, __x: int) -> str: ...
    |}
    DoesNotImplement;
  ()


let test_class_attributes _ =
  let setup source =
    let parent =
      match parse_last_statement ~convert:true source with
      | { Node.value = Class definition; _ } ->
          definition
      | _ ->
          failwith "Could not parse class"
    in
    populate source
    |> fun environment ->
    TypeCheck.resolution environment (),
    Class.create (Node.create_with_default_location parent)
  in

  let resolution, parent =
    setup
      {|
        class type:
          type.__name__: str = 'asdf'
        foo: foo
        class Metaclass:
          def Metaclass.implicit(cls) -> int:
            return 0

        class Attributes(metaclass=Metaclass):
          def Attributes.bar(self) -> int:
            pass
          def Attributes.baz(self, x:int) -> int:
            pass
          def Attributes.baz(self, x:str) -> str:
            pass
        class foo():
          def foo.__init__(self):
            self.implicit: int = 1
          foo.first: int
          foo.second: int
          foo.third: int = 1
          foo.class_attribute: typing.ClassVar[int]
      |}
  in

  let create_attribute
      ?value
      ?(annotation = Some !"int")
      ?defines
      ?(async = false)
      ?(setter = false)
      ?(property = false)
      ?(primitive = false)
      ?(toplevel = true)
      name =
    +{
      Statement.Attribute.name;
      annotation;
      defines;
      value;
      async;
      setter;
      property;
      primitive;
      toplevel;
    }
  in

  (* Test `Class.attributes`. *)
  let assert_attributes definition attributes =
    Annotated.Class.Attribute.Cache.clear ();
    let attribute_list_equal =
      let equal left right =
        (Attribute.name left) = (Attribute.name right) &&
        Type.equal (Attribute.parent left) (Attribute.parent right)
      in
      List.equal ~equal
    in
    let print_attributes attributes =
      let print_attribute { Node.value = { Annotated.Attribute.name; _ }; _ } = name in
      List.map attributes ~f:print_attribute
      |> String.concat ~sep:", "
    in
    assert_equal
      ~cmp:attribute_list_equal
      ~printer:print_attributes
      (Class.attributes ~resolution definition)
      attributes
  in
  assert_attributes
    parent
    [
      Attribute.create ~resolution ~parent (create_attribute "__init__");
      Attribute.create ~resolution ~parent (create_attribute "class_attribute");
      Attribute.create ~resolution ~parent (create_attribute "first");
      Attribute.create ~resolution ~parent (create_attribute "implicit");
      Attribute.create ~resolution ~parent (create_attribute "second");
      Attribute.create
        ~resolution
        ~parent
        (create_attribute "third" ~value:(+Integer 1));
    ];


  (* Test `Attribute`. *)
  let attribute =
    Attribute.create
      ~resolution
      ~parent
      (create_attribute ~annotation:(Some !"int") "first")
  in
  assert_equal
    (Attribute.name attribute)
    "first";
  assert_equal
    (Attribute.annotation attribute)
    (Annotation.create_immutable ~global:true (Type.Primitive "int"));
  assert_false (Attribute.class_attribute attribute);

  let attribute =
    Attribute.create
      ~resolution
      ~parent
      (create_attribute
         ~annotation:(Some (
           Type.expression ~convert:true (Type.parametric "typing.ClassVar" [Type.integer])))
         "first")
  in
  assert_true (Attribute.class_attribute attribute);

  (* Test `attribute_fold`. *)
  let assert_fold ?(class_attributes = false) source fold =
    Annotated.Class.Attribute.Cache.clear ();
    let callback names attribute = (Attribute.name attribute) :: names in
    let resolution, parent = setup source in
    let actual =
      Class.attribute_fold ~class_attributes ~resolution ~initial:[] ~f:callback parent
      |> List.sort ~compare:String.compare
    in
    assert_equal
      ~printer:(List.to_string ~f:ident)
      (List.sort ~compare:String.compare fold)
      actual
  in

  assert_fold
    {|
      class type:
        type.__name__: str = 'asdf'
      foo: foo
      class foo():
        def foo.__init__(self):
          self.implicit: int = 1
        foo.first: int
        foo.second: int
        foo.third: int = 1
        foo.class_attribute: typing.ClassVar[int]
    |}
    [
      "__init__";
      "class_attribute";
      "first";
      "implicit";
      "second";
      "third";
    ];
  assert_fold
    ~class_attributes:true
    {|
      class type:
        type.__name__: str = 'asdf'
      foo: foo
      class foo():
        def foo.__init__(self):
          self.implicit: int = 1
        foo.first: int
        foo.second: int
        foo.third: int = 1
        foo.class_attribute: typing.ClassVar[int]
    |}
    [
      "__init__";
      "class_attribute";
      "first";
      "implicit";
      "second";
      "third";
      "__name__";
      "__call__";
      "__doc__";
      "__getitem__";
      "__init__";
      "__new__";
      "__sizeof__";
    ];
  assert_fold
    ~class_attributes:true
    {|
      class type:
        type.__type__: str
      class Meta(type):
        Meta.__meta__: str
      class Foo(metaclass=Meta):
        Foo.__static__: typing.ClassVar[int]
        Foo.__instance__: int
    |}
    [
      "__instance__";
      "__static__";
      "__meta__";
      "__name__";
      "__doc__";
      "__type__";
      "__call__";
      "__getitem__";
      "__init__";
      "__new__";
      "__sizeof__";
    ];

  (* Test 'attribute' *)
  let assert_attribute ~parent ~parent_instantiated_type ~attribute_name ~expected_attribute =
    let instantiated, class_attributes =
      if Type.is_meta parent_instantiated_type then
        Type.single_parameter parent_instantiated_type, true
      else
        parent_instantiated_type, false
    in
    let actual_attribute =
      Node.create_with_default_location parent
      |> Class.create
      |> Class.attribute
        ~transitive:true
        ~class_attributes
        ~resolution
        ~name:attribute_name
        ~instantiated
      |> Node.value
    in
    assert_equal
      ~cmp:Attribute.equal_attribute
      ~printer:Attribute.show_attribute
      expected_attribute
      actual_attribute
  in
  let parent =
    {|
    class Attributes(metaclass=Metaclass):
      def Attributes.bar(self) -> int:
        pass
      def Attributes.baz(self, x:int) -> int:
        pass
      def Attributes.baz(self, x:str) -> str:
        pass
      @property
      def Attributes.property(self) -> str:
        pass
    |}
    |> parse_single_class ~convert:true
  in
  let create_expected_attribute
      ?(property = false)
      ?(parent = Type.Primitive "Attributes")
      name
      callable =
    {
      Class.Attribute.name;
      parent;
      annotation = (
        Annotation.create_immutable ~global:true (parse_callable callable)
      );
      value = Node.create_with_default_location Ellipsis;
      defined = true;
      class_attribute = false;
      async = false;
      initialized = false;
      property;
    }
  in
  assert_attribute
    ~parent
    ~parent_instantiated_type:(Type.Primitive "Attributes")
    ~attribute_name:"bar"
    ~expected_attribute:(
      create_expected_attribute
        "bar"
        "typing.Callable('Attributes.bar')[[], int]");
  assert_attribute
    ~parent
    ~parent_instantiated_type:(Type.Primitive "Attributes")
    ~attribute_name:"baz"
    ~expected_attribute:(
      create_expected_attribute
        "baz"
        "typing.Callable('Attributes.baz')[[Named(x, int)], int]");
  assert_attribute
    ~parent
    ~parent_instantiated_type:(Type.meta (Type.Primitive "Attributes"))
    ~attribute_name:"implicit"
    ~expected_attribute:(
      create_expected_attribute
        ~parent:(Type.Primitive "Metaclass")
        "implicit"
        "typing.Callable('Metaclass.implicit')[[], int]");
  assert_attribute
    ~parent
    ~parent_instantiated_type:(Type.meta (Type.Primitive "Attributes"))
    ~attribute_name:"property"
    ~expected_attribute:(create_expected_attribute ~property:true "property" "str")


let test_fallback_attribute _ =
  let assert_fallback_attribute ~name source annotation =
    Class.Attribute.Cache.clear ();
    let resolution =
      populate source
      |> fun environment -> TypeCheck.resolution environment ()
    in
    let attribute =
      parse_last_statement ~convert:true source
      |> (function
          | { Node.location; value = Statement.Class definition; _ } ->
              Class.create (Node.create ~location definition)
          | _ ->
              failwith "Last statement was not a class")
      |> Class.fallback_attribute ~resolution ~name
    in
    match annotation with
    | None ->
        assert_is_none attribute
    | Some annotation ->
        assert_is_some attribute;
        let attribute = Option.value_exn attribute in
        assert_equal
          ~cmp:Type.equal
          ~printer:Type.show
          annotation
          (Attribute.annotation attribute |> Annotation.annotation)
  in

  assert_fallback_attribute
    ~name:"attribute"
    {|
      class Foo:
        pass
    |}
    None;
  assert_fallback_attribute
    ~name:"attribute"
    {|
      class Foo:
        def Foo.__getattr__(self, attribute: str) -> int:
          return 1
    |}
    (Some Type.integer);
  assert_fallback_attribute
    ~name:"attribute"
    {|
      class Foo:
        def Foo.__getattr__(self, attribute: str) -> int: ...
    |}
    (Some Type.integer);
  assert_fallback_attribute
    ~name:"attribute"
    {|
      class Foo:
        def Foo.__getattr__(self, attribute: str) -> int: ...
      class Bar(Foo):
        pass
    |}
    (Some Type.integer);

  assert_fallback_attribute
    ~name:"__iadd__"
    {|
      class Foo:
        def Foo.__add__(self, other: Foo) -> int:
          pass
    |}
    (Some (parse_callable "typing.Callable('Foo.__add__')[[Named(other, Foo)], int]"));
  assert_fallback_attribute
    ~name:"__iadd__"
    {|
      class Foo:
        pass
    |}
    None;
  assert_fallback_attribute
    ~name:"__iadd__"
    {|
      class Foo:
        def Foo.__getattr__(self, attribute) -> int: ...
    |}
    (Some Type.integer)


let test_constraints _ =
  let assert_constraints ~target ~instantiated ?parameters source expected =
    let resolution =
      populate source
      |> fun environment -> TypeCheck.resolution environment ()
    in
    let target =
      let { Source.statements; _ } = parse source in
      let target = function
        | { Node.location; value = Statement.Class ({ Statement.Class.name; _ } as definition) }
          when Reference.show name = target ->
            Some (Class.create { Node.location; value = definition })
        | _ ->
            None
      in
      List.find_map ~f:target statements
      |> value
    in
    let constraints =
      parse_last_statement ~convert:true source
      |> (function
          | { Node.location; value = Statement.Class definition; _ } ->
              Class.create (Node.create ~location definition)
          | _ ->
              failwith "Last statement was not a class")
      |> Class.constraints ~target ~resolution ?parameters ~instantiated
    in
    assert_equal
      ~printer:(map_printer ~key_pp:Type.pp ~data_pp:Type.pp)
      ~cmp:(Type.Map.equal Type.equal)
      (Type.Map.of_alist_exn expected)
      constraints
  in
  let int_and_foo_string_union = Type.Union [Type.parametric "Foo" [Type.string]; Type.integer ] in
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [int_and_foo_string_union])
    {|
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_V]):
        pass
    |}
    [Type.variable "_V", int_and_foo_string_union];

  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.Primitive "Foo")
    {|
      class Foo:
        pass
    |}
    [];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.Bottom])
    {|
      _T = typing.TypeVar('_T')
      class Foo(typing.Generic[_T]):
        pass
    |}
    [Type.variable "_T", Type.Bottom];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.integer; Type.float])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        pass
    |}
    [Type.variable "_K", Type.integer; Type.variable "_V", Type.float];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.integer; Type.float])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Foo(typing.Generic[_K, _V]):
        pass
    |}
    [Type.variable "_K", Type.integer; Type.variable "_V", Type.float];

  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.Primitive "Foo")
    {|
      _T = typing.TypeVar('_T')
      class Bar(typing.Generic[_T]):
        pass
      class Foo(Bar[int]):
        pass
    |}
    [];
  assert_constraints
    ~target:"Bar"
    ~instantiated:(Type.Primitive "Foo")
    {|
      _T = typing.TypeVar('_T')
      class Bar(typing.Generic[_T]):
        pass
      class Foo(Bar[int]):
        pass
    |}
    [Type.variable "_T", Type.integer];

  assert_constraints
    ~target:"Bar"
    ~instantiated:(Type.parametric "Foo" [Type.integer])
    {|
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_V]):
        pass
      class Foo(typing.Generic[_K], Bar[_K]):
        pass
    |}
    [Type.variable "_V", Type.integer];

  assert_constraints
    ~target:"Bar"
    ~instantiated:(Type.parametric "Foo" [Type.integer; Type.float])
    {|
      _T = typing.TypeVar('_T')
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_T]):
        pass
      class Baz(typing.Generic[_T]):
        pass
      class Foo(typing.Generic[_K, _V], Bar[_K], Baz[_V]):
        pass
    |}
    [Type.variable "_T", Type.integer];
  assert_constraints
    ~target:"Baz"
    ~instantiated:(Type.parametric "Foo" [Type.integer; Type.float])
    {|
      _T = typing.TypeVar('_T')
      _K = typing.TypeVar('_K')
      _V = typing.TypeVar('_V')
      class Bar(typing.Generic[_T]):
        pass
      class Baz(typing.Generic[_T]):
        pass
      class Foo(typing.Generic[_K, _V], Bar[_K], Baz[_V]):
        pass
    |}
    [Type.variable "_T", Type.float];

  assert_constraints
    ~target:"Iterator"
    ~instantiated:(Type.parametric "Iterator" [Type.integer])
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
    |}
    [Type.variable "_T", Type.integer];

  assert_constraints
    ~target:"Iterator"
    ~instantiated:(Type.parametric "Iterable" [Type.integer])
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
      class Iterable(Iterator[_T]):
        pass
    |}
    [Type.variable "_T", Type.integer];

  assert_constraints
    ~target:"Iterator"
    ~instantiated:(Type.parametric "Iterable" [Type.parametric "Iterable" [Type.integer]])
    ~parameters:[Type.parametric "Iterable" [Type.variable "_T"]]
    {|
      _T = typing.TypeVar('_T')
      class Iterator(typing.Protocol[_T]):
        pass
      class Iterable(Iterator[_T]):
        pass
    |}
    [Type.variable "_T", Type.integer];

  assert_constraints
    ~target:"Foo"
    ~parameters:[Type.parametric "Foo" [Type.variable "_T"]]
    ~instantiated:(Type.parametric "Bar" [Type.parametric "Bar" [Type.integer]])
    {|
      _V = typing.TypeVar('_V', covariant=True)
      class Foo(typing.Generic[_V]):
        pass
      _V2 = typing.TypeVar('_V2')
      class Bar(Foo[_V2]):
        pass
    |}
    [Type.variable "_T", Type.integer];

  let t_bound =
    Type.variable ~constraints:(Type.Variable.Bound (Type.Primitive "Bound")) "T_Bound"
  in
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.Primitive "Bound"])
    {|
      class Bound:
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [t_bound, Type.Primitive "Bound"];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.Primitive "UnderBound"])
    {|
      class Bound:
        pass
      class UnderBound(Bound):
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [t_bound, Type.Primitive "UnderBound"];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.Primitive "OverBound"])
    {|
      class Bound:
        pass
      class OverBound():
        pass
      T_Bound = typing.TypeVar('T_Bound', bound=Bound)
      class Foo(typing.Generic[T_Bound]):
        pass
    |}
    [];
  let t_explicit =
    Type.variable ~constraints:(Type.Variable.Explicit [Type.integer; Type.string]) "T_Explicit"
  in
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.integer])
    {|
      T_Explicit = typing.TypeVar('T_Explicit', int, str)
      class Foo(typing.Generic[T_Explicit]):
        pass
    |}
    [t_explicit, Type.integer];
  assert_constraints
    ~target:"Foo"
    ~instantiated:(Type.parametric "Foo" [Type.bool])
    {|
      T_Explicit = typing.TypeVar('T_Explicit', int, str)
      class Foo(typing.Generic[T_Explicit]):
        pass
    |}
    []


let test_inferred_generic_base _ =
  let assert_inferred_generic ~target source expected =
    let ({ Source.statements; _ } as source) = parse source in
    let target =
      let target = function
        | { Node.location; value = Statement.Class ({ Statement.Class.name; _ } as definition) }
          when Reference.show name = target ->
            Some (Class.create { Node.location; value = definition })
        | _ ->
            None
      in
      List.find_map ~f:target statements
      |> value
    in
    let resolution = Test.resolution ~sources:[source] () in
    assert_equal
      ~cmp:(List.equal ~equal:(Argument.equal Expression.equal))
      expected
      (Annotated.Class.inferred_generic_base target ~resolution)
  in
  assert_inferred_generic
    ~target:"C"
    {|
       _T = typing.TypeVar('_T')
       class C:
         pass
     |}
    [];
  assert_inferred_generic
    ~target:"C"
    {|
       _T = typing.TypeVar("_T")
       class List(typing.Generic[_T]):
         pass
       class C(List[_T]):
         pass
     |}
    [{
      Argument.name = None;
      value = Type.expression ~convert:true (Type.parametric "typing.Generic" [Type.variable "_T"]);
    }];
  assert_inferred_generic
    ~target:"List"
    {|
       _T = TypeVar("_T")
       class Iterable(typing.Generic[_T]):
         pass
       class List(Iterable[_T], typing.Generic[_T]):
         pass
     |}
    [];
  assert_inferred_generic
    ~target:"Foo"
    {|
      _T1 = typing.TypeVar('_T1')
      _T2 = typing.TypeVar('_T2')
      class Foo(typing.Dict[_T1, _T2]): pass
    |}
    [{
      Argument.name = None;
      value =
        Type.expression ~convert:true
          (Type.parametric "typing.Generic" [Type.variable "_T1"; Type.variable "_T2"]);
    }];
  assert_inferred_generic
    ~target:"Foo"
    {|
      _T1 = typing.TypeVar('_T1')
      class Foo(typing.Dict[_T1, _T1]): pass
    |}
    [{
      Argument.name = None;
      value =
        Type.expression ~convert:true
          (Type.parametric "typing.Generic" [Type.variable "_T1"]);
    }];

  ()



let test_metaclasses _ =
  let assert_metaclass ~source ~target metaclass =
    let ({ Source.statements; _ } as source) = parse source in
    let target =
      let target = function
        | { Node.location; value = Statement.Class ({ Statement.Class.name; _ } as definition) }
          when Reference.show name = target ->
            Some (Class.create { Node.location; value = definition })
        | _ ->
            None
      in
      List.find_map ~f:target statements
    in
    let resolution = Test.resolution ~sources:[source] () in
    match target with
    | Some target ->
        assert_equal
          (Type.Primitive metaclass)
          (Annotated.Class.metaclass ~resolution target)
    | None ->
        assert_unreached ()
  in
  assert_metaclass
    ~source:{|
       class C:
         pass
    |}
    ~target:"C"
    "type";

  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class C(metaclass=Meta):
        pass
    |}
    ~target:"C"
    "Meta";

  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class C(metaclass=Meta):
        pass
      class D(C):
        pass
    |}
    ~target:"D"
    "Meta";
  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class C(metaclass=Meta):
        pass
      class Other(metaclass=MoreMeta):
        pass
      class D(C, Other):
        pass
    |}
    ~target:"D"
    "MoreMeta";

  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class C(metaclass=Meta):
        pass
      class Other(metaclass=MoreMeta):
        pass
      class D(Other, C):
        pass
    |}
    ~target:"D"
    "MoreMeta";

  (* If we don't have a "most derived metaclass", pick an arbitrary one. *)
  assert_metaclass
    ~source:{|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class OtherMeta(Meta):
        pass
      class C(metaclass=MoreMeta):
        pass
      class Other(metaclass=OtherMeta):
        pass
      class D(Other, C):
        pass
    |}
    ~target:"D"
    "OtherMeta";

   assert_metaclass
    ~source:{|
      class Meta:
        pass
      class MoreMeta(Meta):
        pass
      class OtherMeta(Meta):
        pass
      class C(metaclass=MoreMeta):
        pass
      class Other(metaclass=OtherMeta):
        pass
      class D(C, Other):
        pass
    |}
    ~target:"D"
    "MoreMeta"


let test_overrides _ =
  let resolution =
    populate {|
      class Foo:
        def Foo.foo(): pass
      class Bar(Foo):
        pass
      class Baz(Bar):
        def Baz.foo(): pass
        def Baz.baz(): pass
    |}
    |> fun environment -> TypeCheck.resolution environment ()
  in
  let definition =
    let definition =
      Resolution.class_definition resolution (Type.Primitive "Baz")
      >>| Class.create
    in
    Option.value_exn ~message:"Missing definition."  definition
  in

  assert_is_none (Class.overrides definition ~resolution ~name:"baz");
  let overrides = Class.overrides definition ~resolution ~name:"foo" in
  assert_is_some overrides;
  assert_equal
    ~cmp:String.equal
    (Attribute.name (Option.value_exn overrides))
    "foo";
  assert_equal
    ~cmp:Access.equal
    ~printer:Access.show
    (Option.value_exn overrides
     |> Attribute.parent
     |> Type.show
     |> Access.create)
    (!+"Foo")


let () =
  "class">:::[
    "attributes">::test_class_attributes;
    "constraints">::test_constraints;
    "constructors">::test_constructors;
    "fallback_attribute">::test_fallback_attribute;
    "generics">::test_generics;
    "get_decorator">::test_get_decorator;
    "implements">::test_implements;
    "inferred_generic_base">::test_inferred_generic_base;
    "is_protocol">::test_is_protocol;
    "metaclasses">::test_metaclasses;
    "methods">::test_methods;
    "overrides">::test_overrides;
    "superclasses">::test_superclasses;
  ]
  |> Test.run
