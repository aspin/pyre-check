(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Pyre
open Expression
open Statement


type t = {
  aliased_exports: (Reference.t * Reference.t) list;
  empty_stub: bool;
  handle: File.Handle.t option;
  wildcard_exports: Reference.t list;
}
[@@deriving compare, eq, sexp]

(* We cache results of `from_empty_stub` here since module definition lookup requires shared memory
   lookup, which can be expensive *)
module Cache = struct
  let cache = Reference.Table.create ()

  let clear () = Reference.Table.clear cache
end


let pp format { aliased_exports; empty_stub; handle; wildcard_exports } =
  let aliased_exports =
    List.map aliased_exports
      ~f:(fun (source, target) ->
          Format.asprintf "%a -> %a" Reference.pp source Reference.pp target)
    |> String.concat ~sep:", "
  in
  let wildcard_exports =
    List.map wildcard_exports ~f:(Format.asprintf "%a" Reference.pp)
    |> String.concat ~sep:", "
  in
  Format.fprintf format
    "%s: [%s, empty_stub = %b, __all__ = [%s]]"
    (Option.value ~default:"unknown path" (handle >>| File.Handle.show))
    aliased_exports
    empty_stub
    wildcard_exports


let show =
  Format.asprintf "%a" pp


let empty_stub { empty_stub; _ } =
  empty_stub


let from_empty_stub ~reference ~module_definition =
  let rec is_empty_stub ~lead ~tail =
    match tail with
    | head :: tail ->
        begin
          let lead = lead @ [head] in
          let reference = Reference.create_from_list lead in
          match module_definition reference with
          | Some definition when empty_stub definition -> true
          | Some _ -> is_empty_stub ~lead ~tail
          | _ -> false
        end
    | _ ->
        false
  in
  Hashtbl.find_or_add Cache.cache reference ~default:(fun _ ->
      is_empty_stub ~lead:[] ~tail:(Reference.as_list reference))


let handle { handle; _ } =
  handle


let wildcard_exports { wildcard_exports; _ } =
  wildcard_exports


let create ~qualifier ~local_mode ?handle ~stub statements =
  let aliased_exports =
    let aliased_exports aliases { Node.value; _ } =
      match value with
      | Assign {
          Assign.target = { Node.value = Name (Name.Identifier target); _ };
          value = { Node.value = Name value; _ };
          _;
        } when Expression.is_simple_name value ->
          let target = Reference.create target in
          let value = Reference.from_name value in
          if Reference.is_strict_prefix ~prefix:qualifier value then
            Map.set aliases ~key:(Reference.sanitized target) ~data:value
          else
            aliases
      | Import { Import.from = Some from; imports } ->
          let from = Source.expand_relative_import ?handle ~qualifier ~from in
          let export aliases { Import.name; alias } =
            let alias = Option.value alias ~default:name in
            let name =
              if String.equal (Reference.show alias) "*" then from else Reference.combine from name
            in
            (* The problem this bit solves is that we may generate an alias prefix <- prefix.rest
               after qualification, which would cause an infinite loop when folding over
               prefix.attribute. To avoid this, drop the prefix whenever we see that the
               qualified alias would cause a loop. *)
            let source, target =
              if Reference.is_strict_prefix ~prefix:(Reference.combine qualifier alias) name then
                alias, Reference.drop_prefix ~prefix:qualifier name
              else
                alias, name
            in
            Map.set aliases ~key:source ~data:target
          in
          List.fold imports ~f:export ~init:aliases
      | Import { Import.from = None; imports } ->
          let export aliases { Import.name; alias } =
            let alias = Option.value alias ~default:name in
            let source, target =
              if Reference.is_strict_prefix ~prefix:(Reference.combine qualifier alias) name then
                alias, Reference.drop_prefix ~prefix:qualifier name
              else
                alias, name
            in
            Map.set aliases ~key:source ~data:target
          in
          List.fold imports ~f:export ~init:aliases
      | _ ->
          aliases
    in
    List.fold statements ~f:aliased_exports ~init:Reference.Map.empty
    |> Map.to_alist
  in
  let toplevel_public, dunder_all =
    let gather_toplevel (public_values, dunder_all) { Node.value; _ } =
      let filter_private =
        let is_public name =
          let dequalified =
            Reference.drop_prefix ~prefix:qualifier name
            |> Reference.sanitize_qualified
          in
          if not (String.is_prefix ~prefix:"_" (Reference.show dequalified)) then
            Some dequalified
          else
            None
        in
        List.filter_map ~f:is_public
      in
      match value with
      | Assign {
          Assign.target = { Node.value = Name (Name.Identifier target); _ };
          value = { Node.value = (Expression.List names); _ };
          _;
        } when String.equal (Identifier.sanitized target) "__all__" ->
          let to_reference = function
            | { Node.value = Expression.String { value = name; _ }; _ } ->
                Reference.create name
                |> Reference.last
                |> (fun last -> if String.is_empty last then None else Some last)
                >>| Reference.create
            | _ -> None
          in
          public_values, Some (List.filter_map ~f:to_reference names)
      | Assign { Assign.target = { Node.value = Name target; _ }; _ }
        when Expression.is_simple_name target ->
          public_values @ (filter_private [target |> Reference.from_name]), dunder_all
      | Class { Record.Class.name; _ } ->
          public_values @ (filter_private [name]), dunder_all
      | Define { Define.signature = { name; _ }; _ } ->
          public_values @ (filter_private [name]), dunder_all
      | Import { Import.imports; _ } ->
          let get_import_name { Import.alias; name } = Option.value alias ~default:name in
          public_values @ (filter_private (List.map imports ~f:get_import_name)), dunder_all
      | _ ->
          public_values, dunder_all
    in
    List.fold ~f:gather_toplevel ~init:([], None) statements
  in
  {
    aliased_exports;
    empty_stub = stub && Source.equal_mode local_mode Source.PlaceholderStub;
    handle;
    wildcard_exports = (Option.value dunder_all ~default:toplevel_public);
  }


let aliased_export { aliased_exports; _ } access =
  Reference.Map.of_alist aliased_exports
  |> (function
      | `Ok exports -> Some exports
      | _ -> None)
  >>= (fun exports -> Map.find exports access)


let in_wildcard_exports { wildcard_exports; _ } reference =
  List.exists ~f:(Reference.equal reference) wildcard_exports
