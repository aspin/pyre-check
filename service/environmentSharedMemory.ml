(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open Analysis
open Ast

module SharedMemory = Memory


(** Keys *)
module TypeKey = struct
  type t = Type.t
  let to_string = Type.serialize
  let compare = Type.compare
  type out = string
  let from_string x = x
end

module StringKey = struct
  type t = string
  let to_string = ident
  let compare = String.compare
  type out = string
  let from_string x = x
end

module LocationKey = struct
  type t = Location.t
  let to_string = Location.Reference.show
  let compare = Location.Reference.compare
  type out = string
  let from_string x = x
end


(** Values *)
module FunctionKeyValue = struct
  type t = Reference.t list
  let prefix = Prefix.make ()
  let description = "Function keys"
end

module GlobalKeyValue = struct
  type t = Reference.t list
  let prefix = Prefix.make ()
  let description = "Global keys"
end

module AliasKeyValue = struct
  type t = Type.t list
  let prefix = Prefix.make ()
  let description = "Alias keys"
end

module ClassKeyValue = struct
  type t = Identifier.t list
  let prefix = Prefix.make ()
  let description = "Class keys"
end

module ProtocolValue = struct
  type t = Identifier.Set.Tree.t
  let prefix = Prefix.make ()
  let description = "Protocols"
end

module DependentKeyValue = struct
  type t = Reference.t list
  let prefix = Prefix.make ()
  let description = "Dependent keys"
end

module ProtocolKeyValue = struct
  type t = Identifier.t list
  let prefix = Prefix.make ()
  let description = "Protocol keys"
end

module ClassValue = struct
  type t = Statement.Class.t Node.t
  let prefix = Prefix.make ()
  let description = "Class"
end

module ClassMetadataValue = struct
  type t = Analysis.Resolution.class_metadata
  let prefix = Prefix.make ()
  let description = "Class metadata"
end

module AliasValue = struct
  type t = Type.t
  let prefix = Prefix.make ()
  let description = "Alias"
end

module GlobalValue = struct
  type t = Resolution.global
  let prefix = Prefix.make ()
  let description = "Global"
end

module DependentValue = struct
  type t = Reference.Set.Tree.t
  let prefix = Prefix.make ()
  let description = "Dependent"
end

module OrderIndexValue = struct
  type t = int
  let prefix = Prefix.make ()
  let description = "Order indices"
end

module OrderAnnotationValue = struct
  type t = Type.t
  let prefix = Prefix.make ()
  let description = "Order annotations"
end

module EdgeValue = struct
  type t = Analysis.TypeOrder.Target.t list
  let prefix = Prefix.make ()
  let description = "Edges"
end

module BackedgeValue = struct
  type t = Analysis.TypeOrder.Target.t list
  let prefix = Prefix.make ()
  let description = "Backedges"
end

module OrderKeyValue = struct
  type t = int list
  let prefix = Prefix.make ()
  let description = "Order keys"
end

module ConfigurationValue = struct
  type t = Configuration.Analysis.t
  let prefix = Prefix.make ()
  let description = "Configuration"
end

module ErrorsValue = struct
  type t = (File.Handle.t * (Analysis.Error.t list)) list
  let prefix = Prefix.make ()
  let description = "All errors"
end

(** Shared memory maps *)
module ClassDefinitions = Memory.WithCache (StringKey) (ClassValue)

module ClassMetadata = Memory.WithCache (StringKey) (ClassMetadataValue)

module Aliases = Memory.NoCache (TypeKey) (AliasValue)

module Globals = Memory.WithCache (Ast.SharedMemory.ReferenceKey) (GlobalValue)

module Dependents = Memory.WithCache (Ast.SharedMemory.ReferenceKey) (DependentValue)

module Protocols = Memory.WithCache (Memory.SingletonKey) (ProtocolValue)

(** Keys *)
module FunctionKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (FunctionKeyValue)

module ClassKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (ClassKeyValue)

module GlobalKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (GlobalKeyValue)

module AliasKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (AliasKeyValue)

module DependentKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (DependentKeyValue)

module ProtocolKeys = Memory.WithCache (Ast.SharedMemory.HandleKey) (ProtocolKeyValue)

(** Type order maps *)
module OrderIndices = Memory.WithCache (TypeKey) (OrderIndexValue)

module OrderAnnotations = Memory.WithCache (Ast.SharedMemory.IntKey) (OrderAnnotationValue)

module OrderEdges = Memory.WithCache (Ast.SharedMemory.IntKey) (EdgeValue)

module OrderBackedges = Memory.WithCache (Ast.SharedMemory.IntKey) (BackedgeValue)

module OrderKeys = Memory.WithCache (Memory.SingletonKey) (OrderKeyValue)

module StoredConfiguration = Memory.NoCache (StringKey) (ConfigurationValue)

module ServerErrors = Memory.NoCache (StringKey) (ErrorsValue)

let heap_size () =
  Memory.SharedMemory.heap_size ()
  |> Float.of_int
  |> (fun size -> size /. 1.0e6)
  |> Int.of_float
