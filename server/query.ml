(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)


open Core

open Ast
open Expression
open Protocol
open TypeQuery
open Pyre

exception InvalidQuery of string

let help () =
  let help = function
    | Attributes _ ->
        Some
          "attributes(class_name): Returns a list of attributes, including functions, for a class."
    | ComputeHashesToKeys ->
        None
    | CoverageInFile _ ->
        Some "coverage_in_file('path'): Gives detailed coverage information for the given path."
    | DecodeOcamlValues _ ->
        None
    | DumpDependencies _ ->
        Some
          (Format.sprintf "%s: %s"
             "dump_dependencies('path')"
             "Writes the dependencies of 'path' to `.pyre/dependencies.dot`.")
    | DumpMemoryToSqlite _ ->
        None
    | IsCompatibleWith _ ->
        Some "is_compatible_with(T1, T2): Returns whether T2 can be used in place of T1."
    | Join  _ ->
        Some "join(T1, T2): Returns the least common supertype of T1 and T2."
    | LessOrEqual _ ->
        Some "less_or_equal(T1, T2)"
    | Meet _ ->
        Some "meet(T1, T2): Returns the greatest common subtype of T1 and T2."
    | Methods _ ->
        Some "methods(class_name): Evaluates to the list of methods for `class_name`."
    | NormalizeType _ ->
        Some "normalize_type(T): Resolves all type aliases for `T`."
    | PathOfModule _ ->
        Some "path_of_module(module): Gives an absolute path for `module`."
    | SaveServerState _ ->
        Some "save_server_state('path'): Saves Pyre's serialized state into `path`."
    | Signature _ ->
        Some "signature(function_name): Gives a human-readable signature for `function_name`."
    | Superclasses _ ->
        Some "superclasses(class_name): Returns the list of superclasses for `class_name`."
    | Type _ ->
        Some "type(expression): Evaluates the type of `expression`."
    | TypeAtPosition _ ->
        Some "type_at_position('path', line, column): Returns the type for the given cursor."
    | TypesInFile _ ->
        Some "types_in_file('path'): Returns the list of all types for a given path."
  in
  let path = Path.current_working_directory () in
  let file = File.create path in
  List.filter_map ~f:help [
    Attributes (Reference.create "");
    ComputeHashesToKeys;
    CoverageInFile file;
    DecodeOcamlValues [];
    DumpDependencies file;
    DumpMemoryToSqlite path;
    IsCompatibleWith (Access.create "", Access.create "");
    Join (Access.create "", Access.create "");
    LessOrEqual (Access.create "", Access.create "");
    Meet (Access.create "", Access.create "");
    Methods (Reference.create "");
    NormalizeType (Access.create "");
    PathOfModule (Reference.create "");
    SaveServerState path;
    Signature (Reference.create "");
    Superclasses (Access.create "");
    Type (Node.create_with_default_location Expression.True);
    TypeAtPosition {
      file;
      position = Location.any_position;
    };
    TypesInFile file;
  ]
  |> List.sort ~compare:String.compare
  |> String.concat ~sep:"\n  "
  |> Format.sprintf "Possible queries:\n  %s"


let parse_query
    ~configuration:({ Configuration.Analysis.local_root = root; _ } as configuration)
    query =
  match (PyreParser.Parser.parse [query]) with
  | [{
      Node.value = Statement.Expression {
          Node.value =
            Call { callee = { Node.value = Name (Name.Identifier name); _ }; arguments };
          _;
        };
      _;
    }] ->
      let arguments =
        let convert_argument { Call.Argument.name; value } =
          { Argument.name; value = convert value }
        in
        List.map ~f:convert_argument arguments
      in
      let expression { Argument.value; _ } = value in
      let access = function
        | { Argument.value = { Node.value = Access (SimpleAccess access); _ }; _ } -> access
        | _ -> raise (InvalidQuery "expected access")
      in
      let reference = function
        | { Argument.value = { Node.value = Access (SimpleAccess access); _ }; _ } ->
            Reference.from_access access
        | _ -> raise (InvalidQuery "expected access")
      in
      let string_of_expression = function
        | { Node.value = String { StringLiteral.value; kind = StringLiteral.String }; _ } ->
            value
        | _ ->
            raise (InvalidQuery "expected string")
      in
      let string argument =
        argument
        |> expression
        |> string_of_expression
      in
      begin
        match String.lowercase name, arguments with
        | "attributes", [name] ->
            Request.TypeQueryRequest (Attributes (reference name))
        | "compute_hashes_to_keys", [] ->
            Request.TypeQueryRequest ComputeHashesToKeys
        | "decode_ocaml_values", pairs ->
            let pair_of_strings = function
              | {
                Argument.value = { Node.value = Tuple [serialized_key; serialized_value]; _ };
                _;
              } ->
                  {
                    serialized_key = string_of_expression serialized_key;
                    serialized_value = string_of_expression serialized_value;
                  }
              | { Argument.value; _ } ->
                  raise
                    (InvalidQuery
                       (Format.sprintf
                          "expected pair of strings, got `%s`"
                          (Expression.show value)))
            in
            Request.TypeQueryRequest (DecodeOcamlValues (List.map pairs ~f:pair_of_strings))
        | "decode_ocaml_values_from_file", [path] ->
            let lines =
              let format line =
                line
                |> String.split ~on:','
                |> function
                | [serialized_key; serialized_value] ->
                    Some { serialized_key; serialized_value }
                | _ -> None
              in
              string path
              |> Path.create_absolute
              |> File.create
              |> File.lines
              >>| List.filter_map ~f:format
            in
            begin
              match lines with
              | Some pairs ->
                  Request.TypeQueryRequest (DecodeOcamlValues pairs)
              | None ->
                  raise (InvalidQuery (Format.sprintf "Malformatted file at `%s`" (string path)))
            end
        | "dump_dependencies", [path] ->
            let file =
              Path.create_relative ~root ~relative:(string path)
              |> File.create
            in
            Request.TypeQueryRequest (DumpDependencies file)
        | "dump_memory_to_sqlite", arguments ->
            let path =
              match arguments with
              | [argument] ->
                  let path = string argument in
                  if Filename.is_relative path then
                    Path.create_relative ~root:(Path.current_working_directory ()) ~relative:path
                  else
                    Path.create_absolute ~follow_symbolic_links:false path
              | [] ->
                  Path.create_relative
                    ~root:(Configuration.Analysis.pyre_root configuration)
                    ~relative:"memory.sqlite"
              | _ ->
                  raise (InvalidQuery "Too many arguments to `dump_memory_to_sqlite`")
            in
            Request.TypeQueryRequest (DumpMemoryToSqlite path)
        | "is_compatible_with", [left; right] ->
            Request.TypeQueryRequest (IsCompatibleWith (access left, access right))
        | "join", [left; right] ->
            Request.TypeQueryRequest (Join (access left, access right))
        | "less_or_equal", [left; right] ->
            Request.TypeQueryRequest (LessOrEqual (access left, access right))
        | "meet", [left; right] ->
            Request.TypeQueryRequest (Meet (access left, access right))
        | "methods", [name] ->
            Request.TypeQueryRequest (Methods (reference name))
        | "normalize_type", [name] ->
            Request.TypeQueryRequest (NormalizeType (access name))
        | "path_of_module", [module_access] ->
            Request.TypeQueryRequest (PathOfModule (reference module_access))
        | "save_server_state", [path] ->
            Request.TypeQueryRequest
              (SaveServerState
                 (Path.create_absolute
                    ~follow_symbolic_links:false
                    (string path)))
        | "signature", [name] ->
            Request.TypeQueryRequest (Signature (reference name))
        | "superclasses", [name] ->
            Request.TypeQueryRequest (Superclasses (access name))
        | "type", [argument] ->
            Request.TypeQueryRequest (Type (expression argument))
        | "type_at_position",
          [
            path;
            { Argument.value = { Node.value = Integer line; _ }; _ };
            { Argument.value = { Node.value = Integer column; _ }; _ };
          ] ->
            let file =
              Path.create_relative ~root ~relative:(string path)
              |> File.create
            in
            let position = { Location.line; column } in
            Request.TypeQueryRequest (TypeAtPosition { file; position })
        | "types_in_file", [path] ->
            let file =
              Path.create_relative ~root ~relative:(string path)
              |> File.create
            in
            Request.TypeQueryRequest (TypesInFile file)
        | "coverage_in_file", [path] ->
            let file =
              Path.create_relative ~root ~relative:(string path)
              |> File.create
            in
            Request.TypeQueryRequest (CoverageInFile file)
        | "type_check", arguments ->
            let files =
              arguments
              |> List.map ~f:string
              |> List.map ~f:(fun relative -> Path.create_relative ~root ~relative)
              |> List.map ~f:File.create
            in
            Request.TypeCheckRequest files
        | _ ->
            raise (InvalidQuery "unexpected query call")
      end
  | _ ->
      raise (InvalidQuery "unexpected query")
  | exception PyreParser.Parser.Error message ->
      raise (InvalidQuery ("failed to parse query: " ^ message))
