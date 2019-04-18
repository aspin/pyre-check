(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast

module SharedMemory = Memory


type annotation_map = {
  precondition: Annotation.t Reference.Map.Tree.t;
  postcondition: Annotation.t Reference.Map.Tree.t;
}

type annotations =
  annotation_map Int.Map.Tree.t


let pp_annotations formatter map =
  Format.fprintf formatter "{";
  let pp_annotation_map ~key ~data:{ precondition; postcondition } =
    let pp_state formatter map =
      let pp_element ~key ~data =
        Format.fprintf formatter "\"%a\": \"%a\", "
          Reference.pp key
          Annotation.pp data
      in
      Format.fprintf formatter "{";
      Reference.Map.Tree.iteri map ~f:pp_element;
      Format.fprintf formatter "}";
    in
    Format.fprintf formatter "%d: { \"Precondition\": %a, \"Postcondition\": %a}"
      key
      pp_state precondition
      pp_state postcondition;
  in
  Int.Map.Tree.iteri map ~f:pp_annotation_map


let show_annotations map =
  Format.asprintf "%a" pp_annotations map


module TypeAnnotationsValue = struct
  type t = annotations
  let prefix = Prefix.make ()
  let description = "Node type resolution"
end


module AnnotationsKeyValue = struct
  type t = Reference.t list
  let prefix = Prefix.make ()
  let description = "Node type resolution keys"
end

(** A map of function definitions (indexed by Reference.t key) to
    to annotations for each statement *)
include SharedMemory.WithCache (Ast.SharedMemory.ReferenceKey) (TypeAnnotationsValue)

module Keys = SharedMemory.NoCache (Ast.SharedMemory.HandleKey) (AnnotationsKeyValue)

let remove handles =
  let accesses =
    List.filter_map ~f:Keys.get handles
    |> List.concat
    |> List.filter ~f:mem
    |> KeySet.of_list
  in
  remove_batch accesses;
  Keys.remove_batch (Keys.KeySet.of_list handles)

let add ~handle name value =
  begin
    match Keys.get handle with
    | None -> Keys.add handle [name]
    | Some names -> Keys.add handle (name :: names)
  end;
  add name value

let get_keys ~handles =
  List.filter_map handles ~f:Keys.get
  |> List.concat
