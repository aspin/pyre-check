(** Copyright (c) 2018-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Taint

open TestHelper
module Callable = Interprocedural.Callable


let assert_model ~model_source ~expect =
  let resolution =
    Test.resolution
      ~sources:(Test.typeshed_stubs () @ [Test.parse model_source])
      ()
  in
  let configuration =
    TaintConfiguration.{
      sources = ["TestTest"];
      sinks = ["TestSink"];
      features = ["special"];
      rules = [];
    }
  in
  let models =
    let source = Test.trim_extra_indentation model_source in
    Model.parse ~resolution ~source ~configuration Callable.Map.empty
  in
  let get_model callable =
    let message = Format.asprintf "Model %a missing" Interprocedural.Callable.pp callable in
    Callable.Map.find models callable
    |> Option.value_exn ?here:None ?error:None ~message
  in
  List.iter ~f:(check_expectation ~get_model) expect


let test_source_models _ =
  assert_model
    ~model_source:"def taint() -> TaintSource[TestTest]: ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~returns:[Sources.NamedSource "TestTest"]
        "taint";
    ];
  assert_model
    ~model_source:"os.environ: TaintSource[TestTest] = ..."
    ~expect:[
      outcome
        ~kind:`Object
        ~returns:[Sources.NamedSource "TestTest"]
        "os.environ";
    ];
  assert_model
    ~model_source:"django.http.Request.GET: TaintSource[TestTest] = ..."
    ~expect:[
      outcome
        ~kind:`Object
        ~returns:[Sources.NamedSource "TestTest"]
        "django.http.Request.GET";
    ];
  assert_model
    ~model_source:"def taint() -> TaintSource[Test, UserControlled]: ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~returns:[Sources.Test; Sources.UserControlled]
        "taint";
    ];

  assert_model
    ~model_source:"os.environ: TaintSink[Test] = ..."
    ~expect:[
      outcome
        ~kind:`Object
        ~sink_parameters:[{ name = "$global"; sinks = [Sinks.Test] }]
        "os.environ";
    ]


let test_sink_models _ =
  assert_model
    ~model_source:
      {|
        def sink(parameter: TaintSink[TestSink]):
          ...
      |}
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }
        ]
        "sink";
    ];

  assert_model
    ~model_source:"def sink(parameter0, parameter1: TaintSink[Test]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter1"; sinks = [Sinks.Test] }
        ]
        "sink";
    ];

  assert_model
    ~model_source:"def sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter0"; sinks = [Sinks.Test] };
          { name = "parameter1"; sinks = [Sinks.Test] }
        ]
        "sink";
    ];

  assert_model
    ~model_source:"def sink(parameter0: TaintSink[Test], parameter1: TaintSink[Test]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter0"; sinks = [Sinks.Test] };
          { name = "parameter1"; sinks = [Sinks.Test] }
        ]
        "sink";
    ];

  assert_model
    ~model_source:"def thrift(parameter0: TaintSink[Thrift]) -> TaintSource[Thrift]: ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~returns:[Sources.Thrift]
        ~sink_parameters:[
          { name = "parameter0"; sinks = [Sinks.Thrift] };
        ]
        "thrift";
    ];

  assert_model
    ~model_source:"def xss(parameter: TaintSink[XSS]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter"; sinks = [Sinks.XSS] };
        ]
        "xss";
    ];

  assert_model
    ~model_source:"def multiple(parameter: TaintSink[XSS, Thrift]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter"; sinks = [Sinks.Thrift; Sinks.XSS] };
        ]
        "multiple";
    ]


let test_class_sink_models _ =
  assert_model
    ~model_source:
      {|
        class Sink(TaintSink[TestSink]):
          # Note: the methods are specified here to have them added to the test environment.
          # These need not be specified in actual sink class models.
          def Sink.method(parameter): ...
          def Sink.method_with_multiple_parameters(first, second): ...
      |}
    ~expect:[
      outcome
        ~kind:`Method
        ~sink_parameters:[{ name = "parameter"; sinks = [Sinks.NamedSink "TestSink"] }]
        "Sink.method";
      outcome
        ~kind:`Method
        ~sink_parameters:[
          { name = "first"; sinks = [Sinks.NamedSink "TestSink"] };
          { name = "second"; sinks = [Sinks.NamedSink "TestSink"] };
        ]
        "Sink.method_with_multiple_parameters";
    ]


let test_taint_in_taint_out_models _ =
  assert_model
    ~model_source:"def tito(parameter: TaintInTaintOut): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~tito_parameters:["parameter"]
        "tito";
    ]


let test_taint_in_taint_out_models_alternate _ =
  assert_model
    ~model_source:"def tito(parameter: TaintInTaintOut[LocalReturn]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~tito_parameters:["parameter"]
        "tito";
    ]


let test_union_models _ =
  assert_model
    ~model_source:"def both(parameter: Union[TaintInTaintOut, TaintSink[XSS]]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter"; sinks = [Sinks.XSS] };
        ]
        ~tito_parameters:["parameter"]
        "both";
    ]


let test_source_breadcrumbs _ =
  assert_model
    ~model_source:"def source() -> TaintSource[Test, Via[special]]: ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~returns:[Sources.Test]
        "source";
    ]


let test_sink_breadcrumbs _ =
  assert_model
    ~model_source:"def sink(parameter: TaintSink[Test, Via[special]]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~sink_parameters:[
          { name = "parameter"; sinks = [Sinks.Test] };
        ]
        "sink";
    ]


let test_tito_breadcrumbs _ =
  assert_model
    ~model_source:"def tito(parameter: TaintInTaintOut[Via[special]]): ..."
    ~expect:[
      outcome
        ~kind:`Function
        ~tito_parameters:["parameter"]
        "tito";
    ]


let test_invalid_models _ =
  let assert_invalid_model ~model_source ~expect =
    let resolution =
      Test.resolution
        ~sources:[
          Test.parse
            {|
              def sink(parameter) -> None: pass
              def source() -> None: pass
            |};
        ]
        ()
    in
    let configuration =
      TaintConfiguration.{
        sources = ["A"; "B"];
        sinks = ["X"; "Y"];
        features = [];
        rules = [];
      }
    in
    let error_message =
      try
        Model.parse
          ~resolution
          ~configuration
          ~source:model_source
          Callable.Map.empty
        |> ignore;
        "no failure"
      with
        Failure message | Model.InvalidModel message -> message
    in
    assert_equal ~printer:ident expect error_message
  in

  assert_invalid_model
    ~model_source:"def sink(parameter: TaintSink[X, Unsupported]) -> TaintSource[A]: ..."
    ~expect:"Invalid model for `sink`: Unsupported taint sink `Unsupported`";

  assert_invalid_model
    ~model_source:"def sink(parameter: TaintSink[UserControlled]): ..."
    ~expect:"Invalid model for `sink`: Unsupported taint sink `UserControlled`";

  assert_invalid_model
    ~model_source:"def sink(parameter: SkipAnalysis): ..."
    ~expect:"Invalid model for `sink`: SkipAnalysis annotation must be in return position";

  assert_invalid_model
    ~model_source:"def sink(parameter: TaintSink[X, Y, LocalReturn]): ..."
    ~expect:"Invalid model for `sink`: Invalid TaintSink annotation `LocalReturn`";

  assert_invalid_model
    ~model_source:"def source() -> TaintSource[Invalid]: ..."
    ~expect:"Invalid model for `source`: Unsupported taint source `Invalid`";

  assert_invalid_model
    ~model_source:"def source() -> TaintInTaintOut: ..."
    ~expect:"Invalid model for `source`: Invalid return annotation: TaintInTaintOut";

  assert_invalid_model
    ~model_source:"def sink(parameter: TaintInTaintOut[Test]): ..."
    ~expect:"Invalid model for `sink`: Invalid TaintInTaintOut annotation `Test`";

  assert_invalid_model
    ~model_source:"def sink(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:(
      "Invalid model for `sink`: Unrecognized taint annotation " ^
      "`InvalidTaintDirection.__getitem__.(...)`"
    );

  assert_invalid_model
    ~model_source:"def not_in_the_environment(parameter: InvalidTaintDirection[Test]): ..."
    ~expect:(
      "Invalid model for `not_in_the_environment`: Modeled entity is not part of the environment!"
    );

  assert_invalid_model
    ~model_source:"def sink(): ..."
    ~expect:(
      "Invalid model for `sink`: Model signature parameters do not match implementation " ^
      "`typing.Callable(sink)[[Named(parameter, unknown)], None]`");

  assert_invalid_model
    ~model_source:"def sink(parameter: Any): ..."
    ~expect:"Invalid model for `sink`: Unrecognized taint annotation `Any`";

  assert_invalid_model
    ~model_source:"def sink(parameter: TaintSink[Test, Via[bad_feature]]): ..."
    ~expect:"Invalid model for `sink`: Unrecognized Via annotation `bad_feature`"


let () =
  "taint_model">:::[
    "source_models">::test_source_models;
    "sink_models">::test_sink_models;
    "class_sink_models">::test_class_sink_models;
    "taint_in_taint_out_models">::test_taint_in_taint_out_models;
    "taint_union_models">::test_union_models;
    "test_source_breadcrumbs">::test_source_breadcrumbs;
    "test_sink_breadcrumbs">::test_sink_breadcrumbs;
    "test_tito_breadcrumbs">::test_tito_breadcrumbs;
    "invalid_models">::test_invalid_models;
  ]
  |> Test.run
