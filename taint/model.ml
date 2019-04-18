(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Analysis
open Expression
open Pyre
open PyreParser
open Interprocedural
open Statement
open Domains
open TaintResult


type t = {
  is_obscure: bool;
  call_target: Callable.t;
  model: TaintResult.call_model;
}
[@@deriving show, sexp]


type breadcrumbs = Features.Breadcrumb.t list
[@@deriving show, sexp]


type taint_annotation =
  | Sink of { sink: Sinks.t; breadcrumbs: breadcrumbs }
  | Source of { source: Sources.t; breadcrumbs: breadcrumbs }
  | Tito of { tito: Sinks.t; breadcrumbs: breadcrumbs }
  | SkipAnalysis  (* Don't analyze methods with SkipAnalysis *)
  | Sanitize      (* Don't propagate inferred model of methods with Sanitize *)
[@@deriving show, sexp]


exception InvalidModel of string


let raise_invalid_model message =
  raise (InvalidModel message)


let add_breadcrumbs breadcrumbs init =
  List.fold
    breadcrumbs
    ~f:(fun set breadcrumb -> Features.Simple.Breadcrumb breadcrumb :: set)
    ~init


let introduce_sink_taint
    ~root
    ({ TaintResult.backward = { sink_taint; _ }; _ } as taint)
    taint_sink_kind
    breadcrumbs =
  let backward =
    let assign_backward_taint environment taint =
      BackwardState.assign
        ~weak:true
        ~root
        ~path:[]
        taint
        environment
    in
    match taint_sink_kind with
    | Sinks.LocalReturn ->
        raise_invalid_model "Invalid TaintSink annotation `LocalReturn`"
    | _ ->
        let leaf_taint =
          BackwardTaint.singleton taint_sink_kind
          |> BackwardTaint.transform
            BackwardTaint.simple_feature_set
            ~f:(add_breadcrumbs breadcrumbs)
          |> BackwardState.Tree.create_leaf
        in
        let sink_taint = assign_backward_taint sink_taint leaf_taint in
        { taint.backward with sink_taint }
  in
  { taint with backward }


let introduce_taint_in_taint_out
    ~root
    ({ TaintResult.backward = { taint_in_taint_out; _ }; _ } as taint)
    taint_sink_kind
    breadcrumbs =
  let backward =
    let assign_backward_taint environment taint =
      BackwardState.assign
        ~weak:true
        ~root
        ~path:[]
        taint
        environment
    in
    match taint_sink_kind with
    | Sinks.LocalReturn ->
        let return_taint =
          Domains.local_return_taint
          |> BackwardTaint.transform
            BackwardTaint.simple_feature_set
            ~f:(add_breadcrumbs breadcrumbs)
          |> BackwardState.Tree.create_leaf in
        let taint_in_taint_out = assign_backward_taint taint_in_taint_out return_taint in
        { taint.backward with taint_in_taint_out }
    | _ ->
        Format.asprintf "Invalid TaintInTaintOut annotation `%s`" (Sinks.show taint_sink_kind)
        |> raise_invalid_model
  in
  { taint with backward }


let introduce_source_taint
    ~root
    ({ TaintResult.forward = { source_taint }; _ } as taint)
    taint_source_kind
    breadcrumbs =
  let source_taint =
    let leaf_taint =
      ForwardTaint.singleton taint_source_kind
      |> ForwardTaint.transform ForwardTaint.simple_feature_set ~f:(add_breadcrumbs breadcrumbs)
      |> ForwardState.Tree.create_leaf
    in
    ForwardState.assign
      ~weak:true
      ~root
      ~path:[]
      leaf_taint
      source_taint
  in
  { taint with forward = { source_taint } }


let extract_identifier = function
  | Access.Identifier name -> Some name
  | _ -> None


type leaf_kind =
  | Leaf of string
  | Breadcrumbs of breadcrumbs


let rec parse_annotations ~configuration annotation =
  let rec extract_breadcrumbs expression =
    let open Configuration in
    match expression.Node.value with
    | Access (SimpleAccess [Identifier breadcrumb]) ->
        [Features.Breadcrumb.simple_via ~allowed:configuration.features breadcrumb]
    | Tuple expressions ->
        List.concat_map ~f:extract_breadcrumbs expressions
    | _ ->
        []
  in
  let rec extract_kinds expression =
    match expression.Node.value with
    | Access (SimpleAccess [Identifier taint_kind]) ->
        [Leaf taint_kind]
    | Access (SimpleAccess (
        (Identifier "Via"
         :: _
         :: Call {
           value = { Argument.value = expression; _; } :: _; _ }
         :: _))) ->
        [Breadcrumbs (extract_breadcrumbs expression)]
    | Tuple expressions ->
        List.concat_map ~f:extract_kinds expressions
    | _ ->
        []
  in
  let extract_leafs expression =
    let kinds, breadcrumbs =
      extract_kinds expression
      |> List.partition_map ~f:(function Leaf l -> `Fst l | Breadcrumbs b -> `Snd b)
    in
    kinds, List.concat breadcrumbs
  in
  let get_source_kinds expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression in
    List.map
      kinds
      ~f:(
        fun kind ->
          Source { source = Sources.parse ~allowed:configuration.sources kind; breadcrumbs }
      )
  in
  let get_sink_kinds expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression in
    List.map
      kinds
      ~f:(fun kind -> Sink { sink = Sinks.parse ~allowed:configuration.sinks kind; breadcrumbs })
  in
  let get_taint_in_taint_out expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression
    in
    match kinds with
    | [] ->
        [Tito { tito = Sinks.LocalReturn; breadcrumbs }]
    | _ ->
        List.map
          kinds
          ~f:(
            fun kind -> Tito { tito = Sinks.parse ~allowed:configuration.sinks kind; breadcrumbs }
          )
  in
  match annotation with
  | Some {
      Node.value =
        Expression.Access
          (SimpleAccess access); _ } ->
      begin
        match access with
        | (Identifier "Union"
           :: _
           :: Call {
             value = { Argument.value = { value = Tuple expressions; _ }; _; } :: _; _ }
           :: _) ->
            List.concat_map
              expressions
              ~f:(fun expression -> parse_annotations ~configuration (Some expression))
        | (Identifier "TaintSink"
           :: _
           :: Call {
             value = { Argument.value = expression; _; } :: _; _ }
           :: _) ->
            get_sink_kinds expression
        | (Identifier "TaintSource"
           :: _
           :: Call {
             value = { Argument.value = expression; _; } :: _; _ }
           :: _) ->
            get_source_kinds expression
        | [Identifier "TaintInTaintOut"] ->
            [Tito { tito = Sinks.LocalReturn; breadcrumbs = [] }]
        | (Identifier "TaintInTaintOut"
           :: _
           :: Call {
             value = { Argument.value = expression; _; } :: _; _ }
           :: _) ->
            get_taint_in_taint_out expression
        | [Identifier "SkipAnalysis"] ->
            [SkipAnalysis]
        | [Identifier "Sanitize"] ->
            [Sanitize]
        | _ ->
            Format.asprintf "Unrecognized taint annotation `%s`" (Expression.Access.show access)
            |> raise_invalid_model
      end
  | None ->
      []
  | Some value ->
      Format.asprintf "Unrecognized taint annotation `%s`" (Expression.show value)
      |> raise_invalid_model


let taint_parameter ~configuration model (root, _name, parameter) =
  let add_to_model model annotation =
    match annotation with
    | Sink { sink; breadcrumbs } ->
        introduce_sink_taint ~root model sink breadcrumbs
    | Source { source; breadcrumbs } ->
        introduce_source_taint ~root model source breadcrumbs
    | Tito { tito; breadcrumbs } ->
        introduce_taint_in_taint_out ~root model tito breadcrumbs
    | SkipAnalysis ->
        raise_invalid_model "SkipAnalysis annotation must be in return position"
    | Sanitize ->
        raise_invalid_model "Sanitize annotation must be in return position"
  in
  let annotation = parameter.Node.value.Parameter.annotation in
  parse_annotations ~configuration annotation
  |> List.fold ~init:model ~f:add_to_model


let taint_return ~configuration model expression =
  let add_to_model model annotation =
    let root = AccessPath.Root.LocalResult in
    match annotation with
    | Sink { sink;  breadcrumbs } ->
        introduce_sink_taint ~root model sink breadcrumbs
    | Source { source; breadcrumbs } ->
        introduce_source_taint ~root model source breadcrumbs
    | Tito _ ->
        raise_invalid_model "Invalid return annotation: TaintInTaintOut"
    | SkipAnalysis ->
        { model with mode = TaintResult.SkipAnalysis; }
    | Sanitize ->
        { model with mode = TaintResult.Sanitize; }
  in
  parse_annotations ~configuration expression
  |> List.fold ~init:model ~f:add_to_model


let create ~resolution ?(verify = true) ~configuration source =
  let signatures =
    let filter_define_signature = function
      | { Node.value = Define { signature = { name; _ } as signature; _ }; _ } ->
          let class_candidate =
            Reference.prefix name
            >>| Resolution.parse_reference resolution
            >>= Resolution.class_definition resolution
          in
          let call_target =
            match class_candidate with
            | Some _ -> Callable.create_method name
            | None -> Callable.create_function name
          in
          [signature, call_target]
      | { Node.value = Class { Class.name; bases; _ }; _ } ->
          let class_sink_base { Call.Argument.value; _ } =
            if Expression.show value |> String.is_prefix ~prefix:"TaintSink[" then
              Some value
            else
              None
          in
          List.find_map bases ~f:class_sink_base
          >>= (fun base ->
              Resolution.class_definition resolution (Type.Primitive (Reference.show name))
              >>| (fun { Node.value = { Class.body; _ }; _ } ->
                  let sink_signature { Node.value; _ } =
                    match value with
                    | Define {
                        Define.signature = { Define.name; parameters; _ } as signature;
                        _;
                      } ->
                        let signature =
                          let parameters =
                            let sink_parameter parameter =
                              let update_annotation parameter =
                                { parameter with Parameter.annotation = Some base }
                              in
                              Node.map parameter ~f:update_annotation
                            in
                            List.map parameters ~f:sink_parameter
                          in
                          { signature with Define.parameters }
                        in
                        Some (signature, Callable.create_method name)
                    | _ ->
                        None
                  in
                  List.filter_map body ~f:sink_signature))
          |> Option.value ~default:[]
      | {
        Node.value =
          Assign {
            Assign.target = { Node.value = Access (SimpleAccess target); _ };
            annotation = Some annotation;
            _;
          };
        _;
      }
        when Expression.show annotation |> String.is_prefix ~prefix:"TaintSource[" ->
          let name = Reference.from_access target in
          let signature =
            {
              Define.name;
              parameters = [];
              decorators = [];
              docstring = None;
              return_annotation = Some annotation;
              async = false;
              parent = None;
            }
          in
          [signature, Callable.create_object name]
      | {
        Node.value =
          Assign {
            Assign.target = { Node.value = Access (SimpleAccess target); _ };
            annotation = Some annotation;
            _;
          };
        _;
      }
        when Expression.show annotation |> String.is_prefix ~prefix:"TaintSink[" ->
          let name = Reference.from_access target in
          let signature =
            {
              Define.name;
              parameters = [Parameter.create ~annotation ~name:"$global" ()];
              decorators = [];
              docstring = None;
              return_annotation = None;
              async = false;
              parent = None;
            }
          in
          [signature, Callable.create_object name]
      | _ ->
          []
    in
    String.split ~on:'\n' source
    |> Parser.parse
    |> Source.create
    |> Preprocessing.convert
    |> Source.statements
    |> List.concat_map ~f:filter_define_signature
  in
  let create_model
      ({ Define.name; parameters; return_annotation; _ }, call_target) =
    try
      begin
        (* Make sure we know about what we model. *)
        let call_target = (call_target :> Callable.t) in
        let annotation = Resolution.resolve resolution (Reference.expression ~convert:true name) in
        if Type.equal annotation Type.Top then
          raise_invalid_model "Modeled entity is not part of the environment!";

        (* Check model matches callables primary signature. *)
        begin
          match verify, annotation with
          | true,
            (Type.Callable {
                Type.Callable.implementation = {
                  Type.Callable.parameters = Type.Callable.Defined implementation_parameters;
                  _;
                };
                implicit;
                _;
              } as callable) ->
              let self_length = if Option.is_some implicit then 1 else 0 in
              if List.length parameters <> self_length + List.length implementation_parameters then
                let message =
                  Format.asprintf
                    "Model signature parameters do not match implementation `%a`"
                    Type.pp callable
                in
                Log.error "%s" message;
                raise_invalid_model message
          | _ ->
              ()
        end;
        AccessPath.Root.normalize_parameters parameters
        |> List.fold ~init:TaintResult.empty_model ~f:(taint_parameter ~configuration)
        |> (fun model -> taint_return ~configuration model return_annotation)
        |> (fun model -> { model; call_target; is_obscure = false })
      end
    with (Failure message | InvalidModel message) ->
      Format.asprintf "Invalid model for `%a`: %s" Reference.pp name message
      |> raise_invalid_model
  in
  List.map signatures ~f:create_model


let subprocess_calls =
  String.Set.of_list [
    "subprocess.run";
    "subprocess.call";
    "subprocess.check_call";
    "subprocess.check_output";
  ]


let model_cache =
  String.Table.create ()


let get_callsite_model ~resolution ~call_target ~arguments =
  let open Pyre in
  let call_target = (call_target :> Callable.t) in
  let subprocess_model =
    let shell_set_to_true ~arguments =
      let shell_set_to_true argument =
        match argument with
        | {
          Argument.name = Some { Node.value = shell; _ };
          value = { Node.value = True; _ };
        } when shell = "$parameter$shell" -> true
        | _ -> false
      in
      List.exists arguments ~f:shell_set_to_true
    in
    let called_with_list =
      let is_list_argument { Argument.name; value } =
        let annotation = Resolution.resolve resolution value in
        Option.is_none name &&
        not (Type.equal annotation Type.Bottom) &&
        not (Type.equal annotation Type.string) &&
        Resolution.less_or_equal
          resolution
          ~left:annotation
          ~right:(Type.list Type.string)

      in
      List.hd arguments
      >>| is_list_argument
      |> (Option.value ~default:true)
    in
    let target = Callable.external_target_name call_target in
    if (not called_with_list) &&
       String.Set.mem subprocess_calls target &&
       shell_set_to_true ~arguments then
      match Hashtbl.find model_cache target with
      | Some model ->
          Some model
      | None ->
          let { model; _ } =
            let model_source =
              Format.asprintf
                "def %s(command: TaintSink[RemoteCodeExecution], shell): ..."
                target
            in
            create ~verify:false ~resolution ~configuration:(Configuration.get ()) model_source
            |> List.hd_exn
          in
          let result = {
            call_target;
            model;
            is_obscure = false;
          }
          in
          Hashtbl.set model_cache ~key:target ~data:result;
          Some result
    else
      None
  in

  match subprocess_model with
  | Some model ->
      model
  | None ->
      match Interprocedural.Fixpoint.get_model call_target with
      | None ->
          { is_obscure = true; call_target; model = TaintResult.empty_model }
      | Some model ->
          let strip_for_call_site model =
            model
          in
          let taint_model =
            Interprocedural.Result.get_model TaintResult.kind model
            |> Option.value ~default:TaintResult.empty_model
            |> strip_for_call_site
          in
          { is_obscure = model.is_obscure; call_target; model = taint_model }


let get_global_model ~resolution ~expression =
  Node.value expression
  |> (function
      | Access (SimpleAccess access) ->
          (match AccessPath.normalize_access ~resolution access with
           | Global access ->
               Some (Reference.from_access access)
           | Access { expression; member } ->
               AccessPath.as_access expression
               |> (fun access -> Expression.Access access)
               |> Node.create_with_default_location
               |> Resolution.resolve resolution
               |> Type.class_name
               |> (fun class_name -> Reference.create ~prefix:class_name member)
               |> Option.some
           | _ ->
               None)
          >>| Callable.create_object
      | _ ->
          None)
  >>| (fun call_target -> get_callsite_model ~resolution ~call_target ~arguments:[])


let parse ~resolution ~source ~configuration models =
  create ~resolution ~configuration source
  |> List.map ~f:(fun model -> (model.call_target, model.model))
  |> Callable.Map.of_alist_reduce ~f:(join ~iteration:0)
  |> Callable.Map.merge models
    ~f:(fun ~key:_ -> function
        | `Both (a, b) -> Some (join ~iteration:0 a b)
        | `Left model | `Right model -> Some model
      )
