(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Expression
open Statement
open Analysis
open Environment


type classdecorator_options = {
  init: bool;
  repr: bool;
  eq: bool;
  order: bool;
}

let transform_environment ~options (module Handler: Handler) resolution source =
  let module Visit = Visit.MakeStatementVisitor(struct
      type t = unit

      let visit_children _ =
        true

      let statement _ _ ast_class =
        match ast_class with
        | { Node.value = Class ({ Class.name = parent;  _ } as ast_class); location } ->
            begin
              let annotated_class = Annotated.Class.create { Node.location; value = ast_class } in
              match options annotated_class with
              | None -> ()
              | Some { init; repr; eq; order } ->
                  let generated_methods =
                    let create_method ~name ~parameters ~return_annotation =
                      {
                        Define.signature = {
                          name = Reference.create ~prefix:parent name;
                          parameters =
                            Parameter.create ~name:"self" ()
                            :: parameters;
                          decorators = [];
                          docstring = None;
                          return_annotation =
                            Some
                              (Node.create
                                 ~location
                                 (Access (SimpleAccess (Access.create return_annotation))));
                          async = false;
                          parent = Some parent;
                        };
                        body = [Node.create ~location Pass];
                      }
                    in
                    let methods =
                      if init && not (
                          Annotated.Class.has_method annotated_class ~resolution ~name:"__init__"
                        ) then
                        let parameters =
                          let collect_parameters parameters attribute =
                            (* Parameters must be annotated attributes *)
                            let annotation =
                              Annotated.Attribute.annotation attribute
                              |> Annotation.original
                              |> function
                              | Type.Parametric {
                                  name = "dataclasses.InitVar";
                                  parameters = [single_parameter];
                                } -> single_parameter
                              | annotation -> annotation
                            in
                            begin
                              match Annotated.Attribute.name attribute with
                              | name when not (Type.is_unknown annotation) ->
                                  let value =
                                    if Annotated.Attribute.initialized attribute then
                                      Some (Annotated.Attribute.value attribute)
                                    else
                                      None
                                  in
                                  let annotation = Type.expression ~convert:true annotation in
                                  let rec override_existing_parameters unchecked_parameters =
                                    match unchecked_parameters with
                                    | [] ->
                                        [Parameter.create ~name ~annotation ?value ()]
                                    | {
                                      Node.value = {
                                        Parameter.name = old_name; value = old_value; _
                                      };
                                      _;
                                    } :: tail
                                      when Identifier.equal old_name name ->
                                        let value =
                                          if Option.is_some value then value else old_value
                                        in
                                        Parameter.create ~name ~annotation ?value () :: tail
                                    | head :: tail ->
                                        head :: override_existing_parameters tail
                                  in
                                  override_existing_parameters parameters
                              | _ ->
                                  parameters
                            end
                          in
                          let parent_dataclasses =
                            Annotated.Class.superclasses ~resolution annotated_class
                            |> List.filter ~f:(fun superclass ->
                                superclass |> options |> Option.is_some)
                            |> (fun superclasses -> annotated_class :: superclasses)
                            |> List.rev
                          in
                          let parent_attributes parent =
                            let compare_by_location left right =
                              Ast.Location.compare (Node.location left) (Node.location right)
                            in
                            Annotated.Class.attributes
                              ~include_generated_attributes:false
                              ~resolution
                              parent
                            |> List.sort ~compare:compare_by_location
                          in
                          parent_dataclasses
                          |> List.map ~f:parent_attributes
                          |> List.fold ~init:[]
                            ~f:(fun parameters -> List.fold ~init:parameters ~f:collect_parameters)
                        in
                        [create_method ~name:"__init__" ~parameters ~return_annotation:"None"]
                      else
                        []
                    in
                    let methods =
                      if repr && not (
                          Annotated.Class.has_method annotated_class ~resolution ~name:"__repr__"
                        ) then
                        let new_method =
                          create_method ~name:"__repr__" ~parameters:[] ~return_annotation:"str"
                        in
                        new_method :: methods
                      else
                        methods
                    in
                    let add_order_method methods name =
                      let annotation = Type.expression ~convert:true Type.object_primitive in
                      if
                        not (Annotated.Class.has_method annotated_class ~resolution ~name)
                      then
                        create_method
                          ~name
                          ~parameters:[Parameter.create ~name:"o" ~annotation ()]
                          ~return_annotation:"bool"
                        :: methods
                      else
                        methods
                    in
                    let methods =
                      if eq then
                        add_order_method methods "__eq__"
                      else
                        methods
                    in
                    let methods =
                      if order then
                        ["__lt__"; "__le__"; "__gt__"; "__ge__"]
                        |> List.fold ~init:methods ~f:add_order_method
                      else
                        methods
                    in
                    methods
                    |> List.rev_map ~f:(fun define -> Node.create ~location (Define define))
                    |> Source.create
                    |> Analysis.Preprocessing.preprocess
                    |> Source.statements
                  in
                  Handler.set_class_definition
                    ~name:(Reference.show parent)
                    ~definition:{
                      Node.location;
                      value = { ast_class with Class.body = generated_methods };
                    }
            end
        | _ ->
            ()
    end)
  in
  Visit.visit () (Preprocessing.convert source)


let extract_options_from_decorator ~names ~default ~init ~repr ~eq ~order annotated_class =
  let get_decorators ~names annotated =
    let get_decorator decorator = Annotated.Class.get_decorator annotated ~decorator in
    names
    |> List.map ~f:get_decorator
    |> List.concat
  in
  let extract_options_from_arguments =
    let apply_arguments default argument =
      let recognize_value ~default = function
        | False -> false
        | True -> true
        | _ -> default
      in
      match argument with
      | {
        Expression.Call.Argument.name = Some { Node.value = argument_name; _ };
        value = { Node.value; _ };
      } ->
          let argument_name = Identifier.sanitized argument_name in
          (* We need to check each keyword sequentially because different keywords may correspond
             to the same string. *)
          let default =
            if String.equal argument_name init then
              { default with init = recognize_value value ~default:default.init }
            else
              default
          in
          let default =
            if String.equal argument_name repr then
              { default with repr = recognize_value value ~default:default.repr }
            else
              default
          in
          let default =
            if String.equal argument_name eq then
              { default with eq = recognize_value value ~default:default.eq }
            else
              default
          in
          let default =
            if String.equal argument_name order then
              { default with order = recognize_value value ~default:default.order }
            else
              default
          in
          default
      | _ ->
          default
    in
    List.fold ~init:default ~f:apply_arguments
  in
  match get_decorators annotated_class ~names with
  | [] ->
      None
  | { Annotated.Class.arguments = Some arguments; _ } :: _ ->
      Some (extract_options_from_arguments arguments)
  | _ ->
      Some default

let transform_dataclass =
  (* TODO (T43210531): Warn about inconsistent annotations *)
  let options =
    extract_options_from_decorator
      ~names:["dataclasses.dataclass"; "dataclass"]
      ~default:{ init = true; repr = true; eq = true; order = false }
      ~init:"init"
      ~repr:"repr"
      ~eq:"eq"
      ~order:"order"
  in
  transform_environment ~options

let transform_attrs =
  (* TODO (T41039225): Add support for other methods *)
  let options =
    extract_options_from_decorator
      ~names:["attr.s"; "attr.attrs"]
      ~default:{ init = true; repr = true; eq = true; order = true }
      ~init:"init"
      ~repr:"repr"
      ~eq:"cmp"
      ~order:"cmp"
  in
  transform_environment ~options
