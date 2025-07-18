(*
The type for a dynamic library: A normal WebAssembly module
plus the dylink section.
*)

open Wasm_exts.Ast
open Wasm.Source
open Wasm_exts.CustomModule
module I64_convert = Wasm.I64_convert

(*
This module is a first stab that should be functionally working, but will go
through further refactoring before we are happy with it. Things to do:

 * much code (finding imports, counting) is duplicated for globals and
   functions. This could be refactored into general functions and predicates.
 * There are multiple AST traversals. These could be turned into a single one
   (taking multiple rename functions) or even more generally taking a record
   of functions for each syntactic category.
*)

(*
Resolving GOT.func and GOT.mem imports
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GOT.func and GOT.mem imports arise from function and data pointers,
respectively, in languages with pointers (e.g. C and Rust). The idea is that if
a shared library exposes a function/data pointer the entire process should use
the same pointer for the function/data so that the pointer arithmetic and
comparisons will work. For example, this C code:

    __attribute__ ((visibility("default")))
    int f0(int x, int y)
    {
        return x + y;
    }

    __attribute__ ((visibility("default")))
    int (\*f1(void)) (int x, int y)
    {
        return &f0;
    }

generates this GOT.func import:

    (import "GOT.func" "f0" (global (;N;) (mut i32)))

The host is responsible of allocating a table index for this function and
resolving the import to the table index for `f0` so that this code in the
importing module would work:

    assert(f1() == f0);

Note that the definition of `f1` is in the *imported* module and this assertion
is in the *importing* module.

Exposing a data pointer generates a GOT.mem import. This is to support 
accesses to the data and pointer equality and pointer arithmetics.
All GOT.mem imports should resolve to the absolute pointer of their exported data. 
The corresponding export of the GOT.mem denotes the pointer offset relative
to the memory base of the module.

(Pointer arithmetic on function pointers are undefined behavior in C and is not
supported by clang's wasm backend)

Normally this stuff is for dynamic linking, but we want to link the RTS
statically, so we resolve these imports during linking. We only support 
GOT.func and GOT.mem imports in the module that defines the function that we 
take the address of. This currently works as moc-generated code doesn't import 
function addresses or data pointers from the RTS.

We resolve GOT imports in two steps:

- After loading the RTS module we collect GOT imports and determine their
  implementation in the defining module (the RTS):

  For each `GOT.func` import, we determine the corresponding function index, 
  e.g. `f0` in the example above.
  For each `GOT.mem` import, we detemine the corresponding global storing the 
  data offset relative to the memory base of the library.

  This is implemented in `collect_got_imports`.

- After merging the sections, we replace the GOT imports with globals in the 
  module section.

  For each `GOT.func`, we create an element in the table with the function index
  determined in the first step. The `GOT.func` import is replaced by a global
  that refers to the new table element.

  For each `GOT.mem`, we replace the GOT accesses in the AST by code that computes 
  the absolute address of the data. This is the library's memory base plus the 
  relative data offset stored in the global as determined in the first step.  
  The `GOT.mem` import is replaced by a dummy global that only serves to maintain 
  the numbering of the globals.
  
  Note that we don't reuse table entries when a function is already in the
  table, to avoid breakage when [ref-types] proposal is implemented, which will
  allow mutating table entries.
  [ref-types]: https://github.com/WebAssembly/reference-types

  The GOT globals are moved to the beginning of the module's global. For simplicity,
  we restrict the GOT globals to only occur at the end of the imported globals.

  This is implemented in `replace_got_imports`.

See also the tests `test/ld/fun-ptr` for concrete examples of GOT resolutions. 
*)

(* Linking *)
exception LinkError of string
exception TooLargeDataSegments of string


let safe_map = Lib.List.safe_map

type imports = (int32 * name) list

let map_module f (em : extended_module) = { em with module_ = f em.module_ }
let map_name_section f (em : extended_module) = { em with name = f em.name }

(* Distinction between Memory64 and Memory32 *)

let uses_memory64 (m: module_') : bool =
  let open Wasm_exts.Types in
  let MemoryType(_, index_type) = match m.memories with
  | [] -> raise (LinkError "Expect at least one memory in module")
  | memory::_ -> memory.it.mtype
  in
  match index_type with
  | I64IndexType -> true
  | I32IndexType -> false

(* Generic functions about import and export lists *)

let get_import is_thing j m =
  let open Int32 in
  let rec go i = function
    | [] -> assert false
    | imp::is ->
      if is_thing imp.it.idesc.it
      then
        if i = j
        then imp
        else go (add i 1l) is
      else go i is
  in go 0l m.imports

let find_imports is_thing libname m : imports =
  let name = Lib.Utf8.decode libname in
  let rec go i acc = function
    | [] -> List.rev acc
    | imp::is ->
      if is_thing imp.it.idesc.it
      then
        if imp.it.module_name = name
        then go (i + 1) ((Int32.of_int i, imp.it.item_name) :: acc) is
        else go (i + 1) acc is
      else go i acc is
  in go 0 [] m.imports

let remove_imports is_thing resolved : module_' -> module_' = fun m ->
  let rec go i = function
    | [] -> []
    | (imp::is) ->
      if is_thing imp.it.idesc.it
      then
        if List.mem_assoc i resolved
        then go (Int32.add i 1l) is
        else imp :: go (Int32.add i 1l) is
      else imp :: go i is
  in
  { m with imports = go 0l m.imports }

let count_imports is_thing m =
  Lib.List32.length (List.filter (fun i -> is_thing i.it.idesc.it) m.imports)

let remove_export is_thing name : module_' -> module_' = fun m ->
  let to_remove e =
    not (is_thing e.it.edesc.it <> None && e.it.name = Lib.Utf8.decode name)
  in
  { m with exports = List.filter to_remove m.exports }

module NameMap = Map.Make(struct type t = Wasm.Ast.name let compare = compare end)

type exports = int32 NameMap.t

let find_exports is_thing m : exports =
  List.fold_left (fun map exp ->
    match is_thing exp.it.edesc.it with
    | Some v -> NameMap.add exp.it.name v.it map
    | _ -> map
  ) NameMap.empty m.exports


(* Predicate to specialize these generic functions to the various entities *)

let is_fun_import = function
  | FuncImport _ -> true
  | _ -> false

let is_global_import = function
  | GlobalImport _ -> true
  | _ -> false

let is_table_import = function
  | TableImport _ -> true
  | _ -> false

let is_memory_import = function
  | MemoryImport _ -> true
  | _ -> false

let is_fun_export = function
  | FuncExport v -> Some v
  | _ -> None

let is_global_export = function
  | GlobalExport v -> Some v
  | _ -> None


let get_fun_typ i m : Wasm_exts.Types.func_type =
  let imports_n = count_imports is_fun_import m in
  let tyvar =
    if i < imports_n
    then
      match (get_import is_fun_import i m).it.idesc.it with
      | FuncImport ty -> ty.it
      | _ -> assert false
    else
      let f = Lib.List32.nth m.funcs (Int32.sub i imports_n) in
      f.it.ftype.it
    in
  (Lib.List32.nth m.types tyvar).it

let get_global_typ i m : Wasm_exts.Types.global_type =
  let imports_n = count_imports is_global_import m in
  if i < imports_n
  then
    match (get_import is_global_import i m).it.idesc.it with
    | GlobalImport ty -> ty
    | _ -> assert false
  else
    let f = Lib.List32.nth m.globals (Int32.sub i imports_n) in
    f.it.gtype

(* Utilities related to functions *)

let remove_fun_imports_name_section resolved : name_section -> name_section = fun ns ->
  let keep (fi, x) = not (List.mem_assoc fi resolved) in
  { ns with
    function_names = List.filter keep ns.function_names;
    locals_names = List.filter keep ns.locals_names;
  }

let prepend_to_start fi ftype (em : extended_module)  =
  let imports_n = count_imports is_fun_import em.module_ in
  let wrap_fi = Int32.add imports_n (Lib.List32.length em.module_.funcs) in

  let wrap_fun = {
    ftype = ftype @@ no_region;
    locals = [];
    body =
      [ Call (fi @@ no_region) @@ no_region ] @
      (match em.module_.start with
        | Some start_fi -> [ Call start_fi @@ no_region ]
        | None -> [])
    } @@ no_region in

  { em with
    module_ =
      { em.module_ with
        funcs = em.module_.funcs @ [ wrap_fun ];
        start = Some (wrap_fi @@ no_region)
      };
    name =
      { em.name with
        function_names = em.name.function_names @ [ wrap_fi, "link_start" ]
      }
  }

let _remove_non_canister_exports (em : extended_module) : extended_module =
  let is_canister_export (exp : export) = Lib.String.chop_prefix "canister_" (Lib.Utf8.encode exp.it.name) <> None in
  map_module (fun m -> { m with exports = List.filter is_canister_export m.exports }) em

let remove_non_ic_exports (em : extended_module) : extended_module =
  (* We assume that every exported function that does not have an entry in the
   custom types section was only exported for linking, and should not be
   exported in the final module *)
  let is_ic_export (exp : export) =
    Lib.String.chop_prefix "canister_" (Lib.Utf8.encode exp.it.name) <> None ||
    "_start" = Lib.Utf8.encode exp.it.name
  in

  let keep_export exp =
    is_ic_export exp ||
    match exp.it.edesc.it with
      | FuncExport _
      | GlobalExport _ -> false
      | MemoryExport _
      | TableExport _ -> true in

  map_module (fun m -> { m with exports = List.filter keep_export m.exports }) em

(* Generic linking logic *)

type renumbering = int32 -> int32

let resolve imports exports : (int32 * int32) list =
  List.flatten (safe_map (fun (fi, name) ->
    match NameMap.find_opt name exports with
    | Some fi' -> [ (fi, fi') ]
    | None -> []
    ) imports)

let calculate_renaming n_imports1 n_things1 n_imports2 resolved12 resolved21 : (renumbering * renumbering) =
  let open Int32 in

  let n_imports1' = sub n_imports1 (Lib.List32.length resolved12) in
  let n_imports2' = sub n_imports2 (Lib.List32.length resolved21) in

  let rec fun1 i =
    let rec go skipped = function
      | (imp, exp)::is ->
        if i < imp then sub i skipped
        else if i = imp then fun2 exp
        else go (add skipped 1l) is
      | [] ->
        if i < n_imports1
        then sub i skipped
        else sub (add i n_imports2') skipped
    in go 0l resolved12
  and fun2 i =
    let rec go skipped = function
      | (imp, exp)::is ->
        if i < imp then sub (add i n_imports1') skipped
        else if i = imp then fun1 exp
        else go (add skipped 1l) is
      | [] ->
        if i < n_imports2
        then sub (add i n_imports1') skipped
        else sub (add (add i n_imports1') n_things1) skipped
    in go 0l resolved21
  in
  (fun1, fun2)


(* AST traversals *)

let rename_globals rn : module_' -> module_' = fun m ->
  let var' = rn in
  let var = phrase var' in

  let rec instr' = function
    | Block (ty, is) -> Block (ty, instrs is)
    | Loop (ty, is) -> Loop (ty, instrs is)
    | If (ty, is1, is2) -> If (ty, instrs is1, instrs is2)
    | GlobalGet v -> GlobalGet (var v)
    | GlobalSet v -> GlobalSet (var v)
    | i -> i
  and instr i = phrase instr' i
  and instrs is = safe_map instr is in

  let func' f = { f with body = instrs f.body } in
  let func = phrase func' in
  let funcs = safe_map func in

  let const = phrase instrs in

  let global' g = { g with value = const g.value } in
  let global = phrase global' in
  let globals = safe_map global in

  let table_segment' (s : var list segment') = { s with offset = const s.offset; } in
  let table_segment = phrase (table_segment') in
  let table_segments = safe_map table_segment in

  let segment_mode' (dmode : segment_mode') = 
    match dmode with 
      | Passive -> Passive
      | Active { index; offset } -> Active { index; offset = const offset }
      | Declarative -> Declarative
    in
  let segment_mode = phrase (segment_mode') in
  let data_segment' (s : data_segment') = { s with dmode = segment_mode s.dmode; } in
  let data_segment = phrase (data_segment') in
  let data_segments = safe_map data_segment in

  (* The exports are used to resolve `GOT.mem`. 
     Therefore, also update the exported global indices. *)
  let export_desc' = function
  | GlobalExport v -> GlobalExport (var v)
  | other -> other
  in
  let export_desc = phrase (export_desc') in
  let export' (e: export') = { e with edesc = export_desc e.edesc } in
  let export = phrase export' in
  let exports = safe_map export in

  { m with
    funcs = funcs m.funcs;
    globals = globals m.globals;
    elems = table_segments m.elems;
    datas = data_segments m.datas;
    exports = exports m.exports;
  }

let set_global global value = fun m ->
  let rec go i = function
    | [] -> assert false
    | g::gs when i = Int32.to_int global ->
      let open Wasm_exts.Types in
      let global_value = if uses_memory64 m then
        (assert (g.it.gtype = GlobalType (I64Type, Immutable));
        Wasm_exts.Values.I64 (Int64.of_int32 value))
      else
        (assert (g.it.gtype = GlobalType (I32Type, Immutable));
        Wasm_exts.Values.I32 value)
      in
      let g = phrase (fun g' ->
        { g' with value = [Const (global_value @@ g.at) @@ g.at] @@ g.at }
      ) g in
      g :: gs
    | g::gs -> g :: go (i+1) gs
  in
  { m with globals = go 0 m.globals }

let fill_global (global : int32) (value : Wasm_exts.Values.value) (uses_memory64 : bool) : module_' -> module_' = fun m ->
  let rec instr' = function
    | Block (ty, is) -> Block (ty, instrs is)
    | Loop (ty, is) -> Loop (ty, instrs is)
    | If (ty, is1, is2) -> If (ty, instrs is1, instrs is2)
    | GlobalGet v when v.it = global -> Const (value @@ v.at)
    | GlobalSet v when v.it = global -> assert false
    | i -> i
  and instr i = phrase instr' i
  and instrs is = safe_map instr is in

  let func' f = { f with body = instrs f.body } in
  let func = phrase func' in
  let funcs = safe_map func in

  let const = phrase instrs in

  (* For 64-bit, convert the constant expression of the table segment offset to 32-bit. *)
  let const_instr_to_32' = function
    | Const { it = (Wasm_exts.Values.I64 number); at } -> Const ((Wasm_exts.Values.I32 (Int64.to_int32 number)) @@ at)
    | GlobalGet v -> GlobalGet v
    | _ -> assert false
  in
  let const_instr_to_32 i = phrase const_instr_to_32' i in
  let convert_const_to_32' = safe_map const_instr_to_32 in
  let convert_const_to_32 = phrase convert_const_to_32' in
  let table_const offset = 
    let expr = const offset in
    if uses_memory64 then convert_const_to_32 expr else expr
  in

  let global' g = { g with value = const g.value } in
  let global = phrase global' in
  let globals = safe_map global in

  let table_segment' (s : var list segment') = { s with offset = table_const s.offset; } in
  let table_segment = phrase (table_segment') in
  let table_segments = safe_map table_segment in

  let segment_mode' (dmode : segment_mode') = 
    match dmode with 
      | Passive -> Passive
      | Active { index; offset } -> Active { index; offset = const offset }
      | Declarative -> Declarative
    in
  let segment_mode = phrase (segment_mode') in
  let data_segment' (s : data_segment') = { s with dmode = segment_mode s.dmode; } in
  let data_segment = phrase (data_segment') in
  let data_segments = safe_map data_segment in


  { m with
    funcs = funcs m.funcs;
    globals = globals m.globals;
    elems = table_segments m.elems;
    datas = data_segments m.datas;
  }

let rename_funcs_name_section rn (ns : name_section) =
  { ns with
    function_names = safe_map (fun (fi, name) -> (rn fi, name)) ns.function_names;
    locals_names = safe_map (fun (fi, locals) -> (rn fi, locals)) ns.locals_names;
  }

let rename_funcs_extended rn (em : extended_module) =
  { em with
    module_ = rename_funcs rn em.module_;
    name = rename_funcs_name_section rn em.name;
  }

let rename_globals_extended rn (em : extended_module) =
  { em with
    module_ = rename_globals rn em.module_;
  }

let rename_types rn m =
  let ty_var = phrase rn in

  let block_type = function
    | VarBlockType tv -> VarBlockType (ty_var tv)
    | ValBlockType vto -> ValBlockType vto in

  let rec instr' = function
    | CallIndirect (table_index, tv) -> CallIndirect (table_index, (ty_var tv))
    | Block (bty, is) -> Block (block_type bty, instrs is)
    | Loop (bty, is) -> Loop (block_type bty, instrs is)
    | If (bty, is1, is2) -> If (block_type bty, instrs is1, instrs is2)
    | i -> i
  and instr i = phrase instr' i
  and instrs is = safe_map instr is in

  let func' f = { f with ftype = ty_var f.ftype; body = instrs f.body } in
  let func = phrase func' in
  let funcs = safe_map func in

  let idesc' = function
    | FuncImport tv -> FuncImport (ty_var tv)
    | id -> id in
  let idesc = phrase idesc' in
  let import' i = { i with idesc = idesc i.idesc } in
  let import = phrase import' in
  let imports = safe_map import in

  { m with
    funcs = funcs m.funcs;
    imports = imports m.imports;
  }

(* Setting and getting top-level module data *)

let read_global gi (m : module_') : int32 =
  let n_impo = count_imports is_global_import m in
  let g = List.nth m.globals (Int32.(to_int (sub gi n_impo))) in
  let open Wasm_exts.Types in
  match uses_memory64 m, g.it.value.it with
  | true, [{ it = Const {it = Wasm_exts.Values.I64 i;_}; _}] -> 
    assert (g.it.gtype = GlobalType (I64Type, Immutable));
    Int64.to_int32 i
  | false, [{ it = Const {it = Wasm_exts.Values.I32 i;_}; _}] ->
    assert (g.it.gtype = GlobalType (I32Type, Immutable));
    i
  | _ -> assert false

let read_table_size (m : module_') : int32 =
  (* Assumes there is one table *)
  let open Wasm_exts.Types in
  match m.tables with
  | [t] ->
    let TableType ({min;max}, _) = t.it.ttype in
    if Some min <> max
    then raise (LinkError "Expect fixed sized table in first module")
    else min
  | _ -> raise (LinkError "Expect one table in first module")

let set_memory_size new_size_bytes : module_' -> module_' = fun m ->
  let open Wasm_exts.Types in
  let page_size = Int64.of_int (64*1024) in
  let new_size_pages = Int64.(add (div new_size_bytes page_size) 1L) in
  let index_type = if uses_memory64 m then I64IndexType else I32IndexType in
  match m.memories with
  | [t;t1] ->
    { m with
      memories = [(phrase (fun m ->
        { mtype = MemoryType ({min = new_size_pages; max = None}, index_type) }
        ) t); t1]
    }
  | [t] ->
    { m with
      memories = [phrase (fun m ->
        { mtype = MemoryType ({min = new_size_pages; max = None}, index_type) }
      ) t]
    }
  | _ -> raise (LinkError "Expect one memory in first module")

let set_table_size new_size : module_' -> module_' = fun m ->
  let open Wasm_exts.Types in
  match m.tables with
  | [t] ->
    { m with
      tables = [ phrase (fun t ->
        let TableType (_, ty) = t.ttype in
        { ttype = TableType ({min = new_size; max = Some new_size}, ty) }
      ) t ]
    }
  | _ -> raise (LinkError "Expect one table in first module")


let fill_item_import module_name item_name new_base uses_memory64 (m : module_') : module_' =
  (* We need to find the right import,
     replace all uses of get_global of that import with the constant,
     and finally rename all globals
  *)
  let base_global =
    let rec go i = function
      | [] -> assert false
      | imp::is -> match imp.it.idesc.it with
        | GlobalImport _ty
          when imp.it.module_name = Lib.Utf8.decode module_name &&
               imp.it.item_name = Lib.Utf8.decode item_name ->
          Int32.of_int i
        | GlobalImport _ ->
          go (i + 1) is
        | _ ->
          go i is
    in go 0 m.imports in

    let new_base_value = if uses_memory64 then
      Wasm_exts.Values.I64 (I64_convert.extend_i32_u new_base)
    else
      Wasm_exts.Values.I32 new_base
    in

    m |> fill_global base_global new_base_value uses_memory64
      |> remove_imports is_global_import [base_global, base_global]
      |> rename_globals Int32.(fun i ->
          if i < base_global then i
          else if i = base_global then assert false
          else sub i one
        )

let fill_memory_base_import new_base uses_memory64 : module_' -> module_' =
  fill_item_import "env" "__memory_base" new_base uses_memory64

let fill_table_base_import new_base uses_memory64 : module_' -> module_' = fun m ->
  let m = fill_item_import "env" "__table_base" new_base uses_memory64 m in
  if uses_memory64 then
    fill_item_import "env" "__table_base32" new_base uses_memory64 m
  else
    m
   
(* Concatenation of modules *)

let join_modules
      (em1 : extended_module) (m2 : module_') (ns2 : name_section)
      (type_indices : (Wasm_exts.Types.func_type, int32) Hashtbl.t) : extended_module =
  let m1 = em1.module_ in
  let joined = 
    { em1 with
      module_ = {
        types = m1.types @ m2.types;
        globals = m1.globals @ m2.globals;
        tables = m1.tables @ m2.tables;
        memories = m1.memories @ m2.memories;
        funcs = m1.funcs @ m2.funcs;
        start = m1.start;
        elems = m1.elems @ m2.elems;
        datas = m1.datas @ m2.datas;
        imports = m1.imports @ m2.imports;
        exports = m1.exports @ m2.exports;
      };
      name = {
        em1.name with
        function_names = em1.name.function_names @ ns2.function_names;
        locals_names = em1.name.locals_names @ ns2.locals_names;
      };
      motoko = em1.motoko;
    }
  in
  (* If second module has a start, prepend it to the first module's start.
     OK to use `Hashtbl.find` below as the first module will have a start, so
     we'll have the unit function in the type section already. *)
  match m2.start with
  | None -> joined
  | Some fi -> prepend_to_start fi.it (Hashtbl.find type_indices (Wasm_exts.Types.FuncType ([], []))) joined

(* The main linking function *)

let check_typ is_thing get_typ string_of m1 m2 (i1, i2) =
  let t1 = get_typ i1 m1 in
  let t2 = get_typ i2 m2 in
  let imp = get_import is_thing i1 m1 in
  if t1 <> t2 then
    let msg = Printf.sprintf
      "Type mismatch when linking %s.%s:\nimport type: %s\nexport type: %s"
      (string_of_name imp.it.module_name)
      (string_of_name imp.it.item_name)
      (string_of t1)
      (string_of t2)
    in
    raise (LinkError msg)

let check_fun_typ =
  check_typ is_fun_import get_fun_typ Wasm_exts.Types.string_of_func_type
let check_global_typ =
  check_typ is_global_import get_global_typ Wasm_exts.Types.string_of_global_type


let align_i32 p n =
  let open Int32 in
  let p = to_int p in
  shift_left (shift_right_logical (add n (sub (shift_left 1l p) 1l)) p) p

let find_fun_export (name : name) (exports : export list) : var option =
  List.find_map (fun (export : export) ->
    if export.it.name = name then
      match export.it.edesc.it with
      | FuncExport var -> Some var
      | _ -> raise (LinkError (Format.sprintf "Export %s is not a function" (Lib.Utf8.encode name)))
    else
      None
  ) exports

let find_global_export (name : name) (exports : export list) : var option =
  List.find_map (fun (export : export) ->
    if export.it.name = name then
      match export.it.edesc.it with
      | GlobalExport var -> Some var
      | _ -> raise (LinkError (Format.sprintf "Export %s is not global" (Lib.Utf8.encode name)))
    else
      None
  ) exports

let remove_got_imports (imports : import list) : import list =
  let got_func_str = Lib.Utf8.decode "GOT.func" in
  let got_mem_str = Lib.Utf8.decode "GOT.mem" in
  let is_got name = name = got_func_str || name = got_mem_str in
  List.filter (fun import -> not (is_got import.it.module_name)) imports

let mk_i32_const (i : int32) =
  Const (Wasm_exts.Values.I32 i @@ no_region) @@ no_region

let mk_i32_global (i : int32) =
  { gtype = Wasm_exts.Types.GlobalType (Wasm_exts.Types.I32Type, Wasm_exts.Types.Immutable);
    value = [mk_i32_const i] @@ no_region }

let mk_i64_const (i : int64) =
  Const (Wasm_exts.Values.I64 i @@ no_region) @@ no_region

let mk_i64_global (i : int64) =
  { gtype = Wasm_exts.Types.GlobalType (Wasm_exts.Types.I64Type, Wasm_exts.Types.Immutable);
    value = [mk_i64_const i] @@ no_region }

type got_func = {
  function_index: int32;
}

type got_mem = {
  exported_global_index: int32;
}

type got_kind =
| GotFunc of got_func
| GotMem of got_mem

type got_import = {
  global_index: int32;
  global_type: Wasm_exts.Types.global_type;
  kind: got_kind;
}

let get_global_type import = match import.it.idesc.it with
  | GlobalImport global_type -> global_type
  | _ -> raise (LinkError "GOT.mem import is not global")

let resolve_got_func global_index import m =
  let name = import.it.item_name in
  let function_index =
    match find_fun_export name m.exports with
    | None -> raise (LinkError (Format.sprintf "Can't find export for GOT.func import %s" (Lib.Utf8.encode name)))
    | Some export_idx -> export_idx.it
  in
  let global_type = get_global_type import in
  {
    global_index;
    global_type;
    kind = GotFunc { function_index }
  }

let resolve_got_mem global_index import m =
  let name = import.it.item_name in
  let exported_global_index =
    match find_global_export name m.exports with
    | None -> raise (LinkError (Format.sprintf "Can't find export for GOT.mem import %s" (Lib.Utf8.encode name)))
    | Some export_idx -> export_idx.it
  in
  let global_type = get_global_type import in
  {
    global_index;
    global_type;
    kind = GotMem { exported_global_index }
  }

let collect_got_imports (m : module_') : got_import list =
  let got_func_name = Lib.Utf8.decode "GOT.func" in
  let got_mem_name = Lib.Utf8.decode "GOT.mem" in

  let get_got_import (allow_normal_globals, global_index, imports) import : (bool * int32 * got_import list) =
    let next_index = Int32.add global_index (Int32.of_int 1) in
    if import.it.module_name = got_func_name then
      let got_func = resolve_got_func global_index import m in
      (false, next_index, got_func :: imports)
    else if import.it.module_name = got_mem_name then
      let got_mem = resolve_got_mem global_index import m in
      (false, next_index, got_mem :: imports)
    else
      (* Implementation restriction: No normal imported globals after GOT globals.
      If this would be required in the future, the GOT globals cannot simply be
      moved to the beginning of the module's global section because the global
      indices would then change and the global accesses in the AST would need
      to be patched. *)
      let continue_index =
        if is_global_import import.it.idesc.it then 
          (assert allow_normal_globals;    
          next_index)
        else global_index
      in
      (allow_normal_globals, continue_index, imports)
  in
  let (_, _, got_imports) =
    List.fold_left get_got_import (true, 0l, []) m.imports
  in
  got_imports

(* For each GOT.mem access, we compute the absolute address of the data pointer.
   This is done by adding the library memory base (`lib_heap_start`) to the offset
   that is stored in the exported global that corresponds to the GOT.mem import. *)
let patch_got_mem_accesses got_mem_imports memory_base = fun m ->
  let phrase_one_to_many f x = safe_map (fun y -> { x with it = y }) (f x.it) in

  let find_got_mem global_index =
    List.find_opt (fun (index, _, _) -> index = global_index) got_mem_imports
  in

  (* Computes the absolute address of the GOT.mem data pointer *)
  let data_pointer exported_global_index = if uses_memory64 m then
    [ Const (Wasm_exts.Values.I64 (Int64.of_int32 memory_base) @@ no_region);
      GlobalGet (exported_global_index @@ no_region);
      Binary (Wasm_exts.Values.I64 I64Op.Add) ]
  else
    [ Const (Wasm_exts.Values.I32 memory_base @@ no_region);
      GlobalGet (exported_global_index @@ no_region);
      Binary (Wasm_exts.Values.I32 I32Op.Add) ]
  in
  let rec instr' = function
    | GlobalGet v -> 
      (match find_got_mem v.it with
      | Some (_, _, exported_global_index) -> data_pointer exported_global_index
      | None -> [GlobalGet v])
    | GlobalSet v ->
      (match find_got_mem v.it with
      | Some _ -> assert false
      | None -> [GlobalSet v])
    | Block (ty, is) -> [Block (ty, instrs is)]
    | Loop (ty, is) -> [Loop (ty, instrs is)]
    | If (ty, is1, is2) -> [If (ty, instrs is1, instrs is2)]
    | i -> [i]
  and instr (i: instr) : instr list = phrase_one_to_many instr' i
  and instrs (is : instr list) : instr list = List.flatten (safe_map instr is) in

  let func' f = { f with body = instrs f.body } in
  let func = phrase func' in
  let funcs = safe_map func in

  { m with
    funcs = funcs m.funcs;
  }

(* `table_size` is the size of the table in the merged module before adding GOT.func functions *)
(* `lib_memory_base` is the Wasm const targetting the library memory base (start of data segments) *)
let replace_got_imports (lib_memory_base : int32) (table_size : int32) (imports: got_import list) (m : module_') : module_' =
  (* Add functions imported from GOT.func to the table, change GOT.func globals to refer
     to the table index of their corresponding function. *)
  let got_func_imports = List.filter_map (function
      | { global_index; global_type; kind = GotFunc { function_index } } ->
        Some (global_index, global_type, function_index)
      | _ -> None
    ) imports
  in
  let elements = safe_map
    (fun (_, _, function_index) -> function_index @@ no_region)
    got_func_imports
  in
  let offset_global global_type offset = Wasm_exts.Types.(match global_type with
    | GlobalType (I32Type, _) -> mk_i32_global (Int32.add table_size (Int32.of_int offset))
    | GlobalType (I64Type, _) -> mk_i64_global (Int64.add (Int64.of_int32 table_size) (Int64.of_int offset))
    | _ -> raise (LinkError "GOT.func global type is not supported"))
  in
  let function_globals = List.mapi (fun offset (global_index, global_type, _) ->
      (global_index, offset_global global_type offset))
    got_func_imports
  in
  let element_section =
    (* Do not add an empty element section if no GOT.func exist in the module *)
    if got_func_imports = [] then None
    else
      Some {
        index = 0l @@ no_region;
        offset = [ mk_i32_const table_size ] @@ no_region;
        init = elements
      }
  in
  (* Patch AST such that GOT.mem global accesses compute the corresponding data pointers.
     Allocate dummy globals in place of the original GOT.mem to maintain the global numbering. *)
  let memory_imports = List.filter_map (function
      | { global_index; global_type; kind = GotMem { exported_global_index } } ->
        Some (global_index, global_type, exported_global_index)
      | _ -> None
    ) imports
  in
  let dummy_global = Wasm_exts.Types.(function
    | GlobalType (I32Type, _) -> mk_i32_global 0l
    | GlobalType (I64Type, _) -> mk_i64_global 0L
    | _ -> raise (LinkError "GOT.mem global type is not supported"))
  in
  let dummy_globals = safe_map
    (fun (global_index, global_type, _) -> (global_index, dummy_global global_type))
    memory_imports
  in
  let patched_module = patch_got_mem_accesses memory_imports lib_memory_base m in
  let new_elements = match element_section with
    | None -> m.elems
    | Some section -> List.append m.elems [section @@ no_region]
  in
  let new_globals = function_globals @ dummy_globals
    |> List.sort (fun (left, _) (right, _) -> compare left right)
    |> safe_map (fun (_, global) -> global @@ no_region)
  in
  (* Move GOT globals from import section to the beginning of module's global section.
     The movement is based on the following assumption that is checked in `collect_got_imports`:
     No normal globals succeed the GOT globals in the import section. *)
  { patched_module with
    elems = new_elements;
    imports = remove_got_imports m.imports; (* Remove GOT globals at the end of imports section *)
    globals = new_globals @ m.globals (* globals preceed existing globals to keep ordering *)
  }

(* The first argument specifies the global of the first module indicating the
start of free memory *)
let link (em1 : extended_module) libname (em2 : extended_module) =

  let global_exports1 = find_exports is_global_export em1.module_ in

  let heap_global =
    match NameMap.find_opt (Lib.Utf8.decode "__heap_base") global_exports1 with
    | None -> raise (LinkError "First module does not export __heap_base")
    | Some gi -> gi in

  let dylink0_mem_info =
    let rec mem_info = function
    | [] -> raise (LinkError "Second module does not have a dylink.0 mem-info section")
    | MemInfo mem_info :: _ -> mem_info
    | _ :: remainder -> mem_info remainder 
    in
    mem_info em2.dylink0 
  in

  (* Beginning of unused space *)
  let old_heap_start = read_global heap_global em1.module_ in
  let lib_heap_start = align_i32 dylink0_mem_info.memory_alignment old_heap_start in
  let new_heap_start = align_i32 8l (Int32.add lib_heap_start dylink0_mem_info.memory_size) in

  if uses_memory64 em1.module_ then
  begin
    (* The RTS data segments must fit below 4.5MB according to the persistent heap layout. 
      The first 4MB are reserved for the Rust call stack such that RTS data segments are limited to 512KB. *)
    let max_rts_stack_size = 4 * 1024 * 1024 in
    let max_rts_data_segment_size = 512 * 1024 in
    (if (Int32.to_int new_heap_start) > max_rts_stack_size + max_rts_data_segment_size then
      (raise (TooLargeDataSegments (Printf.sprintf "The Wasm data segment size exceeds the supported maxmimum of %nMB." max_rts_data_segment_size)))
    else
      ()
    )
  end else ();

  (* Rust requires a table offset of at least 1 as elem[0] is considered invalid. 
     There are debug checks panicking if the element index is zero.
     On the other hand, elem[0] can be used by the Motoko backend code (em1),
     as correct Rust-generated Wasm code does not call elem[0]. *)
  let old_table_size = Int32.max (read_table_size em1.module_) 1l in
  let lib_table_start = align_i32 dylink0_mem_info.table_alignment old_table_size in

  let uses_memory64 = uses_memory64 em1.module_ in
  
  (* Fill in memory and table base pointers *)
  let dm2 = em2.module_
    |> fill_memory_base_import lib_heap_start uses_memory64
    |> fill_table_base_import lib_table_start uses_memory64 in

  let got_imports = collect_got_imports dm2 in
  
  (* Link functions *)
  let fun_required1 = find_imports is_fun_import libname em1.module_ in
  let fun_required2 = find_imports is_fun_import "env" dm2 in
  let fun_exports1 = find_exports is_fun_export em1.module_ in
  let fun_exports2 = find_exports is_fun_export dm2 in
  (* Resolve imports, to produce a renumbering function: *)
  let fun_resolved12 = resolve fun_required1 fun_exports2 in
  let fun_resolved21 = resolve fun_required2 fun_exports1 in
  let (funs1, funs2) =
    calculate_renaming
      (count_imports is_fun_import em1.module_)
      (Lib.List32.length em1.module_.funcs)
      (count_imports is_fun_import dm2)
      fun_resolved12
      fun_resolved21 in

  List.iter (check_fun_typ em1.module_ dm2) fun_resolved12;
  List.iter (check_fun_typ dm2 em1.module_) fun_resolved21;

  (* Link globals *)
  let global_required1 = find_imports is_global_import libname em1.module_ in
  let global_required2 = find_imports is_global_import "env" dm2 in
  let global_exports2 = find_exports is_global_export dm2 in
  (* Resolve imports, to produce a renumbering *)
  let global_resolved12 = resolve global_required1 global_exports2 in
  let global_resolved21 = resolve global_required2 global_exports1 in
  let (globals1, globals2) =
    calculate_renaming
      (count_imports is_global_import em1.module_)
      (Lib.List32.length em1.module_.globals)
      (count_imports is_global_import dm2)
      global_resolved12
      global_resolved21 in
  assert (global_required1 = []); (* so far, we do not import globals *)

  List.iter (check_global_typ em1.module_ dm2) global_resolved12;
  List.iter (check_global_typ dm2 em1.module_) global_resolved21;

  (* Rename types in both modules to eliminate duplicate types. *)

  (* Maps function types to their indices in the new module we're creating *)
  let type_indices : (Wasm_exts.Types.func_type, int32) Hashtbl.t = Hashtbl.create 100 in

  (* Get index of a function type. Creates a new one if we haven't added this
     type yet. *)
  let add_or_get_ty (ty : Wasm_exts.Types.func_type) =
    match Hashtbl.find_opt type_indices ty with
    | None ->
      let idx = Int32.of_int (Hashtbl.length type_indices) in
      Hashtbl.add type_indices ty idx;
      idx
    | Some idx ->
      idx
  in

  (* Rename a type in a module. First argument is the list of types in the module. *)
  let ty_renamer (tys : Wasm_exts.Types.func_type phrase list) (t : int32) : int32 =
    let fun_ty = List.nth tys (Int32.to_int t) in
    add_or_get_ty fun_ty.it
  in

  let is_active data_segment = match data_segment.it.dmode.it with
  | Active _ -> true
  | _ -> false
  in
  let em1_active_data_segments = List.filter is_active em1.module_.datas in
  let is_passive data_segment = match data_segment.it.dmode.it with 
  | Passive -> true
  | _ -> false
  in
  let em1_passive_data_segments = List.filter is_passive em1.module_.datas in
  
  (* Check that the first module generated by the compiler backend does not use 
     active data segments. *)
  if uses_memory64 then
    assert ((List.length em1_active_data_segments) = 0)
  else ();
  
  let dm2_data_segment_offset = List.length em1_passive_data_segments in

  (* Rename types in first module *)
  let em1_tys =
    map_module (fun m -> { (rename_types (ty_renamer m.types) m) with types = [] }) em1
  in

  (* Rename types in second module *)
  let dm2 =
    { (rename_types (ty_renamer dm2.types) dm2) with types = [] }
  in

  (* Generate type section for the final module *)
  let type_indices_sorted : type_ list =
    Hashtbl.to_seq type_indices |>
    List.of_seq |>
    List.sort (fun (_, idx1) (_, idx2) -> compare idx1 idx2) |>
    safe_map (fun (ty, _) -> ty @@ no_region)
  in

  let add_initial_call function_name =
    match NameMap.find_opt (Lib.Utf8.decode function_name) fun_exports2 with
    | None -> fun em -> em
    | Some fi -> prepend_to_start (funs2 fi) (add_or_get_ty (Wasm_exts.Types.FuncType ([], [])))
  in

  let new_table_size =
    let got_func_imports = List.filter (function 
    | { kind = GotFunc _; _ } -> true
    | _ -> false) got_imports in
    Int32.add (Int32.add lib_table_start dylink0_mem_info.table_size) (Int32.of_int (List.length got_func_imports))
  in

  (* Rust generates active data segments for the runtime system code that are not supported with orthogonal persistence.
     Therefore, for enhanced orthogonal persistence, make the data segments passive and load them on initialization to 
     their reserved static space.
     Note: If Rust would also use passive data segments in future, the segment load indices need to be renumbered. *)
  let make_rts_data_segments_passive : module_' -> module_' = fun m ->
    let segment_mode' (dmode : segment_mode') = 
      match dmode with 
        | Active _ -> Passive
        | _ -> raise (LinkError "Passive data segments are not yet supported in the RTS module")
    in
    let segment_mode = phrase (segment_mode') in
    let data_segment' (s : data_segment') = { s with dmode = segment_mode s.dmode; } in
    let data_segment = phrase (data_segment') in
    let data_segments = safe_map data_segment in
    { m with datas = data_segments m.datas; }
  in

  let load_rts_data_segments numbering_offset data_segments : module_' -> module_' = fun m ->
      let imported_functions = Int32.to_int (count_imports is_fun_import m) in
      let start_index = Int32.to_int (match m.start with
      | Some index -> index.it
      | None -> raise (LinkError "The module has no start function to inject"))
      in
      let local_start_function = Int.sub start_index imported_functions in
      if local_start_function < 0 then
        raise (LinkError "The module start refers to an imported function that cannot be injected");
      assert (local_start_function < (List.length m.funcs));
  
      let load_passive_segment index data_segment =
        let segment_index = Int32.of_int (Int.add index numbering_offset) in
        let compile_const_i32 value = Const (Wasm_exts.Values.I32 value @@ no_region) @@ no_region in
        let data_target = match data_segment.it.dmode.it with
          | Active { offset; _ } -> offset.it
          | _ -> raise (LinkError "Passive data segments are not yet supported in the RTS module")
        in
        let data_length = Int32.of_int (String.length data_segment.it.dinit) in
        let memory_init = MemoryInit (segment_index @@ no_region) @@ no_region in
        data_target @
        [ 
          compile_const_i32 0l; (* data offset *)
          compile_const_i32 data_length; 
          memory_init 
        ]
      in
      let load_passive_segments = List.concat (List.mapi load_passive_segment data_segments) in
  
      let inject_in_func' code f = { f with body = code @ f.body } in
      let inject_in_func code = phrase (inject_in_func' code) in
      let patch_functions functions = 
        List.mapi (fun index func -> 
          if index = local_start_function then
            inject_in_func load_passive_segments func
          else func
        ) functions
      in
      { m with funcs = patch_functions m.funcs; }
    in

  let merged = join_modules
    ( em1_tys
    |> map_module (fun m -> { m with types = type_indices_sorted })
    |> map_module (remove_imports is_fun_import fun_resolved12)
    |> map_name_section (remove_fun_imports_name_section fun_resolved12)
    |> map_module (remove_imports is_global_import global_resolved12)
    |> rename_funcs_extended funs1
    |> rename_globals_extended globals1
    |> map_module (set_global heap_global new_heap_start)
    |> map_module (set_memory_size (I64_convert.extend_i32_u new_heap_start))
    |> map_module (set_table_size new_table_size)
    )
    ( dm2
    |> (if uses_memory64 then make_rts_data_segments_passive else (fun m -> m))
    |> remove_imports is_fun_import fun_resolved21
    |> remove_imports is_global_import global_resolved21
    |> remove_imports is_memory_import [0l, 0l]
    |> remove_imports is_table_import [0l, 0l]
    |> rename_funcs funs2
    |> rename_globals globals2
    |> remove_export is_fun_export "__wasm_call_ctors"
    |> remove_export is_fun_export "__wasm_apply_data_relocs"
    )
    ( em2.name
    |> remove_fun_imports_name_section fun_resolved21
    |> rename_funcs_name_section funs2
    )
    type_indices
  |> add_initial_call "__wasm_call_ctors" (* second call *)
  |> add_initial_call "__wasm_apply_data_relocs" (* very first call before `__wasm_call_ctors` *)
  |> remove_non_ic_exports (* only sane if no additional files get linked in *)
  |> (if uses_memory64 then map_module (load_rts_data_segments dm2_data_segment_offset dm2.datas) else (fun m -> m))
  in

  (* Rename global and function indices in GOT stuff *)
  let got_imports =
    safe_map (function
      | { global_index; global_type; kind = GotFunc { function_index }} ->
        { global_index = globals2 global_index;
          global_type;
          kind = GotFunc { function_index = funs2 function_index }
        }
      | { global_index; global_type; kind = GotMem { exported_global_index }} ->
        { global_index = globals2 global_index;
          global_type;
          kind = GotMem {
            exported_global_index = globals2 exported_global_index;
          }
        }
    ) got_imports
  in

  (* Replace GOT imports with globals referring to implementing functions or data pointers *)
  let table_size = Int32.add lib_table_start dylink0_mem_info.table_size in
  let final = replace_got_imports lib_heap_start table_size got_imports merged.module_ in

  { merged with module_ = final }
