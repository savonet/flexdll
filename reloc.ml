(************************************************************************)
(*   FlexDLL                                                            *)
(*   Alain Frisch                                                       *)
(*                                                                      *)
(*   Copyright 2007 Institut National de Recherche en Informatique et   *)
(*   en Automatique.                                                    *)
(************************************************************************)

(* The main application: parse COFF files,
   compute relocation and export tables, rewrite some COFF files,
   call the native linker *)

open Coff
open Cmdline

let search_path = ref []
let default_libs = ref []

let gcc = ref "gcc"
let objdump = ref "objdump"

let is_crt_lib = function
  | "LIBCMT"
  | "MSVCRT" -> true
  | fn -> false

let flexdir =
  try
    let s = Sys.getenv "FLEXDIR" in
    if s = "" then raise Not_found else s
  with Not_found ->
    Filename.dirname Sys.executable_name

(* Temporary files *)

let temps = ref []

let add_temp fn =
  temps := fn :: !temps; fn

let temp_file s x =
  add_temp (Filename.temp_file s x)

let open_temp_file s x =
  let (f, c) = Filename.open_temp_file s x in (add_temp f, c)

let safe_remove s =
  try Sys.remove s
  with Sys_error _ -> ()

let () =
  at_exit
    (fun () -> if not !save_temps then List.iter safe_remove !temps)

(* Calling external commands *)

let read_file fn =
  let ic = open_in fn in
  let r = ref [] in
  (try while true do r := input_line ic :: !r done with End_of_file -> ());
  close_in ic;
  List.rev !r


let get_output ?(use_bash = false) cmd =
  let fn = Filename.temp_file "flexdll" "" in
  let cmd' = cmd ^ " > " ^ (Filename.quote fn) in
    if String.length cmd' < 8182 && not use_bash then
      begin
	if (Sys.command cmd' <> 0)
	then failwith ("Cannot run " ^ cmd);
      end
    else
      begin
	let (cfn, oc) = open_temp_file "longcmd" ".sh" in
	  output_string oc cmd'; close_out oc;
	  if Sys.command (Printf.sprintf "bash %s" cfn) <> 0
	  then failwith ("Cannot run " ^ cmd)
      end;
    let r = read_file fn in
      Sys.remove fn;
      r

let get_output1 ?use_bash cmd =
  List.hd (get_output ?use_bash cmd)


(* Preparing command line *)

let mk_dirs_opt pr = String.concat " " (List.map (fun s -> pr ^ (Filename.quote s)) !dirs)


(* Build @responsefile to work around Windows limitations on
   command-line length *)
let build_diversion lst =
  let (responsefile, oc) = open_temp_file "camlresp" "" in
  List.iter
    (fun f ->
      if f <> "" then begin
        let s = Filename.quote f in
        for i = 0 to String.length s - 1 do
          if s.[i] = '\\' then s.[i] <- '/'
        done;
        output_string oc s; output_char oc '\n'
      end)
    lst;
  close_out oc;
  "@" ^ responsefile

type cmdline = {
    may_use_response_file: bool;
    mutable too_long: bool;
  }

let new_cmdline () =
  let rf = match !toolchain with
  | `MSVC | `MSVC64 | `LIGHTLD -> true
  | `MINGW | `MINGW64 | `CYGWIN -> false
  in
  {
   may_use_response_file = rf;
   too_long = false;
 }

let run_command cmdline cmd =
  let cmd_quiet =
    match !toolchain with
    | `MSVC | `MSVC64 when !verbose < 1 -> cmd ^ " >NUL"
    | _ -> cmd
  in
  (* note: for Cygwin, using bash allow to follow symlinks to find
     gcc... *)
  if cmdline.too_long || !toolchain = `CYGWIN then begin
    (* Dump the command in a text file and apply bash to it. *)
    let (fn, oc) = open_temp_file "longcmd" "" in
    output_string oc cmd;
    close_out oc;

    if !verbose >= 1 then Printf.printf "(call with bash: %s)\n%!" fn;
    if Sys.command (Printf.sprintf "bash %s" fn) <> 0 then
      failwith "Error during linking\n"
  end else
    if Sys.command cmd_quiet <> 0 then begin
      if cmd <> cmd_quiet then ignore (Sys.command cmd);
      failwith "Error during linking\n"
    end

let quote_files cmdline lst =
  let s =
    String.concat " "
      (List.map (fun f -> if f = "" then f else Filename.quote f) lst) in
  if String.length s >= 1024 then
    if cmdline.may_use_response_file then Filename.quote (build_diversion lst)
    else (cmdline.too_long <- true; s)
  else
    s


(* Looking for files *)

let cygpath l =
  get_output (Printf.sprintf "cygpath -m %s" (String.concat " " (List.map Filename.quote l)))

let file_exists fn =
  if Sys.file_exists fn && not (Sys.is_directory fn) then Some fn
  else if !use_cygpath && Sys.file_exists (fn ^ ".lnk") then
    Some (get_output1 (Printf.sprintf "cygpath -m %s" fn))
  else None

let rec find_file_in = function
  | [] -> None
  | fn::rest ->
      match file_exists fn with
	| Some x -> Some x
	| None -> find_file_in rest

let find_file fn =
  let l =
    List.flatten
      (List.map
	 (fun dir ->
	    let fn = Filename.concat dir fn in
	    [ fn; fn ^ ".lib"; fn ^ ".dll.a"; fn ^ ".a" ]
	 ) (""::!search_path)) in
  match find_file_in l with
    | Some x -> Some x
    | None -> if !use_cygpath then find_file_in (cygpath l) else None


let find_file =
  let memo = Hashtbl.create 16 in
  fun fn ->
    let k = String.lowercase fn in
    try Hashtbl.find memo k
    with Not_found ->
      try Hashtbl.find memo (k ^ ".lib")
      with Not_found ->
        let fn =
	  if String.length fn > 2 && String.sub fn 0 2 = "-l" then
	    "lib" ^ (String.sub fn 2 (String.length fn - 2))
	  else fn in
        let r =
	  match find_file fn with
	  | Some fn -> fn
	  | None ->
	      failwith (Printf.sprintf "Cannot find file %S" fn)
        in
        Hashtbl.add memo k r;
        Hashtbl.add memo (k ^ ".lib") r;
        r


(*******************************)

let int32_to_buf b i =
  Buffer.add_char b (Char.chr (i land 0xff));
  Buffer.add_char b (Char.chr ((i lsr 8) land 0xff));
  Buffer.add_char b (Char.chr ((i lsr 16) land 0xff));
  Buffer.add_char b (Char.chr ((i lsr 24) land 0xff))

let int_to_buf b i =
  assert(i >= 0);
  match !machine with
  | `x86 -> int32_to_buf b i
  | `x64 -> int32_to_buf b i; int32_to_buf b 0

let exportable s =
  match !machine with
  | `x86 ->
      s <> "" && (s.[0] = '_'  || s.[0] = '?')
  | `x64 ->
      if String.length s > 2 && s.[0] = '?' && s.[1] = '?' then false
      else true

let drop_underscore obj s =
  match !machine with
  | `x86 ->
      assert (s <> "");
      begin
        match s.[0] with
        | '_' -> String.sub s 1 (String.length s - 1)
        | '?' -> s
        | _ -> failwith (Printf.sprintf "In %s, symbol %s doesn't start with _ or ?" obj.obj_name s)
      end
  | `x64 ->
      s

let has_prefix pr s =
  String.length s > String.length pr && String.sub s 0 (String.length pr) = pr

let check_prefix pr s =
  if has_prefix pr s then
    Some (String.sub s (String.length pr) (String.length s - String.length pr))
  else None

let parse_libpath s =
  let n = String.length s in
  let rec aux l =
    if l >= n then []
    else
      try
	let i = String.index_from s l ';' in
	String.sub s l (i - l) :: aux (succ i)
      with Not_found -> [ String.sub s l (n - l) ]
  in
  aux 0

module StrSet = Set.Make(String)

(* Put all the relocations on the symbols defined by a predicate
   into a relocation table. A relocation table describes how to
   patch some addresses with the value of some external symbols (given
   by their name). It also lists segments that are normally write-protected
   and that must be de-protected to enable the patching process. *)

let add_reloc_table x p sname =
  let sect = Section.create ".reltbl" 0xc0300040l in
  let data = Buffer.create 1024 in
  let strings = Buffer.create 1024 in
  let nonwr = ref [] in
  let nonwrsym = Symbol.intern sect 0l in
  let strsym = Symbol.intern sect 0l in
  let str_pos = Hashtbl.create 16 in

  Reloc.abs !machine sect 0l nonwrsym;
  int_to_buf data 0;

  (* TODO: use a single symbol per section *)
  let syms = ref [] in
  let reloc sec secsym min max rel =
    if p rel.symbol then (
      (* kind *)
      let kind = match !machine, rel.rtype with
	| `x86, 0x06
        | `x64, 0x01 -> 0x0002 (* absolute, native size (32/64) *)
	| `x86, 0x14
        | `x64, 0x04 -> 0x0001 (* rel32 *)
        | `x64, 0x05 -> 0x0004 (* rel32_1 *)
        | `x64, 0x08 -> 0x0003 (* rel32_4 *)
	| `x64, 0x06 -> 0x0005 (* rel32_2 *)
        | `x86, (0x0a | 0x0b) -> 0x0100 (* debug relocs: ignore *)
	| _, k  ->
            let msg =
              Printf.sprintf "Unsupported relocation kind %04x for %s"
                k rel.symbol.sym_name
            in
            failwith msg
(*            Printf.eprintf "%s\n" msg;
            0x0001 *)
      in
      int_to_buf data kind;

      (* name *)
      let name = drop_underscore x rel.symbol.sym_name in
      let pos =
	try Hashtbl.find str_pos name
	with Not_found ->
	  let pos = Buffer.length strings in
	  Hashtbl.add str_pos name pos;
	  Buffer.add_string strings name;
	  Buffer.add_char strings '\000';
	  pos
      in
      Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) strsym;
      int_to_buf data pos;

      Reloc.abs !machine sect (Int32.of_int (Buffer.length data))
	(Lazy.force secsym);
      int_to_buf data (Int32.to_int rel.addr);

      if rel.addr <= !min then min := rel.addr;
      if rel.addr >= !max then max := rel.addr;
      false
    ) else true
  in
  let section sec =
    let min = ref Int32.max_int and max = ref Int32.min_int in
    let sym = lazy (let s = Symbol.intern sec 0l in
		    syms := s :: !syms;
		    s) in

    sec.relocs <- filter (reloc sec sym min max) sec.relocs;
    if (sec.sec_opts &&& 0x80000000l = 0l) && !min <= !max then
      nonwr := (!min,!max,Lazy.force sym) :: !nonwr
  in
  List.iter section x.sections;
  int_to_buf data 0;
  strsym.value <- Int32.of_int (Buffer.length data);
  Buffer.add_buffer data strings;
  nonwrsym.value <- Int32.of_int (Buffer.length data);
  List.iter
    (fun (min,max,secsym) ->
      Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) secsym;
      int_to_buf data (Int32.to_int min);
      Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) secsym;
      int_to_buf data (Int32.to_int  max);
      int_to_buf data 0;
    )
    !nonwr;
  int_to_buf data 0;
  int_to_buf data 0;
  sect.data <- `String (Buffer.contents data);
  x.sections <- sect :: x.sections;
  x.symbols <-
    (Symbol.export sname sect 0l) ::
    strsym :: nonwrsym :: List.filter (fun x -> not (p x)) x.symbols
    @ !syms


(* Create a table for import symbols __imp_XXX *)

let add_import_table obj imports =
  let sect = Section.create ".imptbl" 0xc0300040l in
  obj.sections <- sect :: obj.sections;
  sect.data <- `String (String.make (4 * List.length imports) '\000');
  ignore
    (List.fold_left
       (fun i s ->
	  let sym = Symbol.extern s in
	  obj.symbols <-
	    sym :: Symbol.export ("__imp_" ^ s) sect (Int32.of_int i) ::
	    obj.symbols;
	  Reloc.abs !machine sect (Int32.of_int i) sym; i + 4)
       0 imports)


(* Create a table that lists exported symbols (adress,name) *)

let add_export_table obj exports symname =
  let sect = Section.create ".exptbl" 0xc0300040l in
  let data = Buffer.create 1024 in
  let strings = Buffer.create 1024 in
  let strsym = Symbol.intern sect 0l in
  obj.symbols <- strsym :: (Symbol.export symname sect 0l) :: obj.symbols;
  let exports = List.sort Pervasives.compare exports in
  (* The runtime library assumes that names are sorted! *)
  int_to_buf data (List.length exports);
  List.iter
    (fun s  ->
       let sym = Symbol.extern s in
       obj.symbols <- sym :: obj.symbols;
       Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) sym;
       int_to_buf data 0;

       Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) strsym;
       int_to_buf data (Buffer.length strings);
       Buffer.add_string strings (drop_underscore obj s);
       Buffer.add_char strings '\000';
    )
    exports;
  strsym.value <- Int32.of_int (Buffer.length data);
  sect.data <- `String (Buffer.contents data ^ Buffer.contents strings);
  obj.sections <- sect :: obj.sections

(* A master relocation table points to all the relocation tables
   in the DLL *)

let add_master_reloc_table obj names symname =
  let sect = Section.create ".mreltbl" 0xc0300040l in
  let data = Buffer.create 1024 in
  obj.symbols <- (Symbol.export symname sect 0l) :: obj.symbols;
  List.iter
    (fun s  ->
       let sym = Symbol.extern s in
       obj.symbols <- sym :: obj.symbols;
       Reloc.abs !machine sect (Int32.of_int (Buffer.length data)) sym;
       int_to_buf data 0;
    )
    names;
  int_to_buf data 0;
  sect.data <- `String (Buffer.contents data);
  obj.sections <- sect :: obj.sections



let collect_dllexports obj =
  let dirs = Coff.directives obj in
  let l = List.map (function  (_,x::_) -> x
    | _ -> assert false)
    (List.find_all (fun (cmd,args) -> String.uppercase cmd = "EXPORT") dirs)
  in
  match !toolchain with
  | `MSVC | `MSVC64 -> List.map (drop_underscore obj) l
  | _ -> l



let exports accu obj =
  List.fold_left
    (fun accu sym ->
       if Symbol.is_defin sym && exportable sym.sym_name
       then StrSet.add sym.sym_name accu
       else accu)
    accu obj.symbols

let needed f accu obj =
  let l = List.filter Symbol.is_extern obj.symbols in
  List.fold_left (fun accu sym -> StrSet.add (f sym.sym_name) accu) accu l

let collect f l =
  List.fold_left
    (fun accu x ->
       match f x with None -> accu | Some y -> y :: accu)
    []
    l

let cmd_verbose cmd =
  if !verbose >= 1 then Printf.printf "+ %s\n" cmd;
  Sys.command cmd


let parse_dll_exports fn =
  let ic = open_in fn in
  let exps = ref [] in
  try
    while input_line ic <> "[Ordinal/Name Pointer] Table" do () done;
    while true do
      let s = input_line ic in
      let r = String.index s ']' in
      let sym = String.sub s (r+2) (String.length s - r - 2) in
      exps := ("_" ^ sym,0) :: !exps;
    done;
    assert false
  with Not_found | End_of_file ->
    close_in ic;
    !exps


let dll_exports fn = match !toolchain with
  | `MSVC | `MSVC64 | `LIGHTLD ->
      failwith "Creation of import library not supported for this toolchain"
  | `CYGWIN | `MINGW | `MINGW64 ->
      let dmp = temp_file "dyndll" ".dmp" in
      if cmd_verbose (Printf.sprintf "%s -p %s > %s" !objdump fn dmp) <> 0
      then failwith "Error while extracting exports from a DLL";
      parse_dll_exports dmp


let patch_output output_file =
  match !stack_reserve with
  | Some x -> Stacksize.set_stack_reserve output_file x
  | None -> ()

let build_dll link_exe output_file files exts extra_args =
  let main_pgm = link_exe <> `DLL in

  (* fully resolve filenames, eliminate duplicates *)
  let _,files =
    List.fold_left (fun (seen,accu) fn ->
		      let fn = find_file fn in
                      let k = String.lowercase fn in
		      if StrSet.mem k seen then (seen, accu)
		      else (StrSet.add k seen, fn :: accu)
		   ) (StrSet.empty,[]) files in
  let files = List.rev files in

  (* load given files *)
  let loaded_filenames : (string,unit) Hashtbl.t = Hashtbl.create 16 in
  let files = List.map (fun fn ->
			  if Lib.is_dll fn then
			    fn,`Lib ([], dll_exports fn)
			  else
			    fn, Lib.read fn) files in

  List.iter (fun (fn,_) -> Hashtbl.add loaded_filenames fn ()) files;

  let objs =
    collect (function (f,`Obj x) -> Some (f,x) | _ -> None) files in
  let libs =
    collect (function (f,`Lib (x,_)) -> Some (f,x) | _ -> None) files in

  let from_imports = ref StrSet.empty in
  let defined = ref StrSet.empty in
  let add_def s = defined := StrSet.add s !defined in
  if main_pgm then add_def (usym "static_symtable")
  else add_def (usym "reloctbl");

  if !machine = `x64 then add_def "__ImageBase"
  else add_def "___ImageBase";

  let aliases = Hashtbl.create 16 in
  let rec normalize name =
    try
      let r = Hashtbl.find aliases name in
      if r <> name then normalize r else r
    with Not_found -> name
  in

  (* Collect all the available symbols, including those defined
     in default libraries *)
  let collected = Hashtbl.create 8 in
  let rec collect_defined_obj obj =
    List.iter (fun (x,y) ->
		 if !verbose >= 2 then
		   Printf.printf "alias %s -> %s\n"
		     x y;
		 Hashtbl.add aliases x y) (Coff.aliases obj);
    let dirs = Coff.directives obj in
    let all_args c =
      List.map snd (
	List.find_all (fun (cmd,args) -> String.uppercase cmd = c)
	  dirs)
    in
    let deflibs = if !builtin_linker || not !use_default_libs then [] else List.flatten (all_args "DEFAULTLIB") in
    List.iter (fun fn ->
      if !custom_crt && is_crt_lib fn then ()
      else
	let fn = find_file fn in
	if not (Hashtbl.mem loaded_filenames fn)
	then (Hashtbl.add loaded_filenames fn (); collect_file fn))
      deflibs;
    List.iter
      (fun sym ->
	 if Symbol.is_defin sym
	 then add_def sym.sym_name
      )
      obj.symbols
  and collect_file fn =
    if not (Hashtbl.mem collected (String.lowercase fn)) then begin
      Hashtbl.replace collected (String.lowercase fn) ();
      if !verbose >= 2 then Printf.printf "** open: %s\n" fn;
      collect_defined fn (Lib.read fn)
    end

  and collect_defined fn = function
    | `Obj obj -> collect_defined_obj obj
    | `Lib (objs,imports) ->
	List.iter (fun (_,obj) -> collect_defined_obj obj) objs;
	List.iter
	  (fun (s,_) ->
	    if !verbose >= 2 then
	       Printf.printf "lib %s import symbol %s\n%!" fn s;
            from_imports := StrSet.add s !from_imports;
            add_def s;
	    add_def ("__imp_" ^ s)
          )
	  imports
  in
  List.iter (fun (fn,x) ->
    Hashtbl.replace collected (String.lowercase fn) ();
    collect_defined fn x) files;
  if !use_default_libs then
    List.iter (fun fn -> collect_file (find_file fn)) !default_libs;
  List.iter (fun fn -> collect_file (find_file fn)) exts;

  (* Determine which objects from the given libraries should be linked
     in. First step: find the mapping (symbol -> object) for these
     objects. *)
  let defined_in = Hashtbl.create 16 in
  let def_in_obj fn (objname,obj) = List.iter
      (fun sym ->
        if Symbol.is_defin sym
        then begin
          if !explain then
            Printf.printf "Symbol %s found in %s(%s)\n%!" sym.sym_name fn
              objname;
          Hashtbl.replace defined_in sym.sym_name (fn,objname,obj);
        end
      ) obj.symbols in
  List.iter
    (fun (fn,objs) ->
      if !explain then
        Printf.printf "Scanning lib %s\n%!" fn;
      List.iter (def_in_obj fn) objs)
    libs;

  let imported_from_implib = ref StrSet.empty in
  let imported = ref StrSet.empty in
  let normalize name =
    let name = normalize name in
    match check_prefix "__imp_" name with
    | Some s when not (StrSet.mem name !defined) && StrSet.mem s !defined -> s
    | _ -> name
  in
  let needed obj = needed normalize StrSet.empty obj in
  let imports obj =
    let n = needed obj in
    imported_from_implib := StrSet.union !imported_from_implib
        (StrSet.inter n !from_imports);
    let undefs = StrSet.diff n !defined in
    StrSet.filter
      (fun s -> match check_prefix "__imp_" s with
      | Some s' -> (*Printf.printf "import for %s: %s\n" obj.obj_name s; *) imported := StrSet.add s' !imported; false
      | None -> true)
      undefs
  in

  (* Second step: transitive closure, starting from given objects *)

  let libobjects  = Hashtbl.create 16 in
  let reloctbls = ref [] in
  let exported = ref StrSet.empty in

  List.iter (fun s -> exported := StrSet.add (usym s) !exported) !defexports;

  (* re-export symbols imported from implibs *)
  (* disabled: symbols may be undefined in the DLL! that would
     raise an error at startup *)
(*
  List.iter
    (function
       | (_,`Lib (_,l)) ->
	   exported := List.fold_left
	     (fun accu (s,_) ->
		if exportable s then StrSet.add s accu
		else accu
	     ) !exported l
       | _ -> ()) files;
*)

  let record_obj name obj =
    if !builtin_linker then ""
    else begin
      let fn = temp_file "dyndll"
        (if !toolchain = `MSVC || !toolchain = `MSVC64 then ".obj" else ".o") in
      let oc = open_out_bin fn in
      Coff.put oc obj;
      close_out oc;
      fn
    end
  in

  let add_reloc name obj imps =
    if !show_imports && not (StrSet.is_empty imps) then (
      Printf.printf "** Imported symbols for %s:\n" name;
      StrSet.iter print_endline imps
    );
    let reloctbl = Symbol.gen_sym () in
    reloctbls := reloctbl :: !reloctbls;
    add_reloc_table obj (fun s -> StrSet.mem s.sym_name imps) reloctbl in

  let errors = ref false in
  let error_imports name imps =
    if main_pgm then begin
      Printf.eprintf "** Cannot resolve symbols for %s:\n %s\n%!"
	name
	(String.concat "\n " (StrSet.elements imps));
      errors := true
    end
  in

  let close_obj name imps obj =
    error_imports name imps;
    add_reloc name obj imps;
    record_obj name obj in

  let dll_exports = ref StrSet.empty in
  let rec link_obj fn obj =
    exported := exports !exported obj;
    dll_exports := List.fold_left (fun accu x -> StrSet.add x accu)
        !dll_exports (collect_dllexports obj);
    StrSet.iter
      (fun s ->
        if StrSet.mem s !exported then ()
        else
          try
            let (libname, objname, _) as o = Hashtbl.find defined_in s in
            if !explain then
              Printf.printf "%s -> %s(%s) because of %s\n%!" fn libname objname s;
            link_libobj o
          with Not_found ->
            if !explain then
              Printf.printf "%s needs %s (not found)\n%!" fn s
      )
      (needed obj)
  and link_libobj (libname,objname,obj) =
    if Hashtbl.mem libobjects (libname,objname) then ()
    else (Hashtbl.replace libobjects (libname,objname) (obj,imports obj);
	  link_obj (Printf.sprintf "%s(%s)" libname objname) obj) in

  let redirect = Hashtbl.create 16 in
  List.iter
    (fun (fn,obj) ->
       link_obj fn obj;
       let imps = imports obj in
       if (StrSet.is_empty imps) then ()
       else Hashtbl.replace redirect fn (close_obj fn imps obj);
    ) objs;

  let need_lib = Hashtbl.create 16 in
  Hashtbl.iter
    (fun (libname,objname) (obj,imps) ->
      if StrSet.is_empty imps
      then Hashtbl.replace need_lib libname ()
          (* the linker will find this object in this library *)
      else begin
        if !explain then
          Printf.printf "Library object %s(%s) needs to be rewritten\n"
            libname objname;
        Hashtbl.add redirect libname
          (close_obj (Printf.sprintf "%s(%s)" libname objname) imps obj)
      end
    )
    libobjects;

  if !show_exports then (
    Printf.printf "** Exported symbols:\n";
    StrSet.iter print_endline !exported;
    Printf.printf "** Symbols from import libs:\n";
    StrSet.iter print_endline !imported_from_implib;
  );

  if !reexport_from_implibs then
    exported := StrSet.union !exported !imported_from_implib;

  (* Create the descriptor object *)
  let obj = Coff.create !machine in

  if not (StrSet.is_empty !imported) then begin
    error_imports "descriptor object" !imported;
    add_import_table obj (StrSet.elements !imported);
    add_reloc "descriptor object" obj !imported;
  end;

  add_export_table obj (if !noexport then [] else StrSet.elements !exported)
    (usym (if main_pgm then "static_symtable" else "symtbl"));
  if not main_pgm then add_master_reloc_table obj !reloctbls (usym "reloctbl");

  if !errors then
    exit 2;

  if !builtin_linker then begin
    let objs = List.map
        (function
           | (_, `Obj obj) -> obj
           | (fn, _) -> failwith ("File is not an object file: " ^ fn)
        ) files
    in
    let oc = open_out_bin output_file in
    Create_dll.create_dll oc (obj :: objs);
    close_out oc
  end else

  let descr = record_obj "descriptor" obj in
  let files =
    List.flatten
      (List.map
	 (fun (fn,d) ->
	   let all = Hashtbl.find_all redirect fn in
	   if all = [] then [fn]
           else
             match d with
             | `Lib _ when Hashtbl.mem need_lib fn -> all @ [fn]
             | `Lib (_, []) | `Obj _ -> all
             | `Lib _ -> all @ [fn]
            (* Note: extracted object have higher priorities
               than objects embedded in the library, so this is ok.
               We always keep libraries with import symbols.
               For mingw, it is necessary to put the library after
               extracted objects. *)
         )
	 files
      )
    @ exts in

  let cmdline = new_cmdline () in
  let files = quote_files cmdline files in
  let descr = Filename.quote descr in

  begin
    match !deffile with
    | Some x when not !dry_mode ->
        let fn =
          if x = "" then Filename.chop_extension output_file ^ ".def"
          else x
        in
        if !verbose >= 1 then Printf.printf "Generate %s\n%!" fn;
        let oc = open_out fn in
        Printf.fprintf oc "LIBRARY %s\n" output_file;
        Printf.fprintf oc "EXPORTS\n";
        StrSet.iter (Printf.fprintf oc "  %s\n") !dll_exports;
        close_out oc
    | _ -> ()
  end;

  let cmd = match !toolchain with
    | `MSVC | `MSVC64 ->
	(* Putting the file the descriptor object at the beginning
	   with MSVC compilers seems to break Stack overflow recovery
	   in OCaml. No idea why. *)

	let implib =
          if !implib then
            Filename.chop_extension output_file ^ ".lib"
          else
            temp_file "dyndll_implib" ".lib"
        in
	let _impexp = add_temp (Filename.chop_suffix implib ".lib" ^ ".exp") in
        let extra_args =
          if !custom_crt then "/nodefaultlib:LIBCMT /nodefaultlib:MSVCRT " ^ extra_args
          else "msvcrt.lib " ^ extra_args
        in

        let extra_args =
          if !machine = `x64 then "/base:0x10000 " ^ extra_args else extra_args
        in
        (* Flexdll requires that all images (main programs and all the DLLs) are
           not too far away. This is needed because of the 32-bit relative relocations
           (e.g. function calls). It seems that passing such a /base argument to link.exe
           gives some hope that this will be the case. Problems observed otherwise
           with the Windows 7 SDK in 64-bit mode. *)

	Printf.sprintf
	  "link /nologo %s%s%s%s%s /implib:%s /out:%s /subsystem:%s %s %s %s"
	  (if !verbose >= 2 then "/verbose " else "")
          (if link_exe = `EXE then "" else "/dll ")
	  (if main_pgm then "" else "/export:symtbl /export:reloctbl ")
	  (if main_pgm then "" else if !noentry then "/noentry " else
          let s =
            match !machine with
            | `x86 -> "FlexDLLiniter@12"
            | `x64 -> "FlexDLLiniter"
          in
          Printf.sprintf "/entry:%s " s
          )
	  (mk_dirs_opt "/libpath:")
	  (Filename.quote implib)
	  (Filename.quote output_file)
          !subsystem
          files descr
	  extra_args
    | `CYGWIN ->
        let def_file =
          if main_pgm then ""
          else
            let def_file, oc = open_temp_file "flexlink" ".def" in
            Printf.fprintf oc "EXPORTS\n  reloctbl\n  symtbl\n";
            close_out oc;
            Filename.quote def_file
        in
	Printf.sprintf
	  "%s %s%s -L. %s %s -o %s %s %s %s %s"
          !gcc
	  (if link_exe = `EXE then "" else "-shared ")
	  (if main_pgm then "" else if !noentry then "-Wl,-e0 " else "-Wl,-e_FlexDLLiniter@12 ")
	  (mk_dirs_opt "-I")
	  (mk_dirs_opt "-L")
	  (Filename.quote output_file)
	  descr
	  files
          def_file
	  extra_args
    | `MINGW | `MINGW64 ->
        let def_file =
          if main_pgm then ""
          else
            let def_file, oc = open_temp_file "flexlink" ".def" in
            Printf.fprintf oc "EXPORTS\n  reloctbl\n  symtbl\n";
            close_out oc;
            Filename.quote def_file
        in
	Printf.sprintf
	  "%s -m%s %s%s -L. %s %s -o %s %s %s %s %s %s"
          !gcc
          !subsystem
	  (if link_exe = `EXE then "" else "-shared ")
	  (if main_pgm then "" else if !noentry then "-Wl,-e0 " else if !machine = `x86 then "-Wl,-e_FlexDLLiniter@12 " else "-Wl,-eFlexDLLiniter ")
	  (mk_dirs_opt "-I")
	  (mk_dirs_opt "-L")
	  (Filename.quote output_file)
	  descr
	  files
          def_file
          (if !implib then "-Wl,--out-implib=" ^ Filename.quote (Filename.chop_extension output_file ^ ".a") else "")
	  extra_args
    | `LIGHTLD ->
        no_merge_manifest := true;
	Printf.sprintf
	  "ld %s%s -o %s %s %s %s %s"
	  (if link_exe = `EXE then "" else "--shared ")
	  (if main_pgm then "" else if !noentry then "-e0 " else "-e FlexDLLiniter@12 ")
	  (Filename.quote output_file)
	  descr
	  files
          (if !implib then "--out-implib " ^ Filename.quote (Filename.chop_extension output_file ^ ".a") else "")
	  extra_args
  in
  if !verbose >= 1 || !dry_mode then Printf.printf "+ %s\n%!" cmd;
  if not !dry_mode then begin
    let manifest_file = output_file ^ ".manifest" in
    safe_remove manifest_file;
    run_command cmdline cmd;

    if (not !no_merge_manifest) && !merge_manifest && (not !real_manifest || Sys.file_exists manifest_file)
    then begin
      let fn =
        if !real_manifest then manifest_file
        else
          let default_manifest =
            match !machine with
            | `x86 -> "default.manifest"
            | `x64 -> "default_amd64.manifest"
          in
          Filename.concat flexdir default_manifest
      in
      let mcmd =
	Printf.sprintf "mt -nologo -outputresource:%s -manifest %s"
	  (Filename.quote (if link_exe = `EXE then output_file
			   else output_file ^ ";#2"))
	  (Filename.quote fn)
      in
      if !verbose >= 1 then Printf.printf "+ %s\n%!" mcmd;
      if Sys.command mcmd <> 0 then
	failwith "Error while merging the manifest";
      safe_remove manifest_file;
    end;

    patch_output output_file
  end


let setup_toolchain () =
  let mingw_libs pre =
    gcc := pre ^ "-gcc";
    objdump := pre ^ "-objdump";
    search_path :=
      !dirs @
      [
       Filename.dirname (get_output1 (!gcc ^ " -print-libgcc-file-name"));
       get_output1 (!gcc ^ " -print-sysroot") ^ "/mingw/lib";
      ];
    default_libs :=
      ["-lmingw32"; "-lgcc"; "-lmoldname"; "-lmingwex"; "-lmsvcrt";
       "-luser32"; "-lkernel32"; "-ladvapi32"; "-lshell32" ];
    if !exe_mode = `EXE then default_libs := "crt2.o" :: !default_libs
    else default_libs := "dllcrt2.o" :: !default_libs
  in
  match !toolchain with
  | _ when !builtin_linker ->
      search_path := !dirs;
      add_flexdll_obj := false;
      noentry := true
  | `CYGWIN ->
      gcc := "gcc";
      objdump := "objdump";
      search_path :=
	!dirs @
	  [
           "/lib";
	   "/lib/w32api";
           Filename.dirname (get_output1 ~use_bash:true "gcc -print-libgcc-file-name");
	  ];
      default_libs := ["-lkernel32"; "-luser32"; "-ladvapi32";
		       "-lshell32"; "-lcygwin"; "-lgcc"]
  | `MSVC | `MSVC64 ->
      search_path := !dirs @
	parse_libpath (try Sys.getenv "LIB" with Not_found -> "");
      if not !custom_crt then
        default_libs := ["msvcrt.lib"]
  | `MINGW ->
      mingw_libs Version.mingw_prefix
  | `MINGW64 ->
      mingw_libs Version.mingw64_prefix
  | `LIGHTLD ->
      search_path := !dirs

let compile_if_needed file =
  if Filename.check_suffix file ".c" then begin
    let tmp_obj = temp_file "dyndll"
      (if !toolchain = `MSVC || !toolchain = `MSVC64 then ".obj" else ".o") in
    let cmd = match !toolchain with
      | `MSVC | `MSVC64 ->
	  Printf.sprintf
	    "cl /c /MD /nologo /Fo%s %s %s"
	    (Filename.quote tmp_obj)
	    (mk_dirs_opt "/I")
	    file
      | `CYGWIN ->
	  Printf.sprintf
	    "gcc -c -o %s %s %s"
	    (Filename.quote tmp_obj)
	    (mk_dirs_opt "-I")
	    file
      | `MINGW | `MINGW64 ->
	  Printf.sprintf
	    "%s -c -o %s %s %s"
            !gcc
	    (Filename.quote tmp_obj)
	    (mk_dirs_opt "-I")
            (Filename.quote file)
      | `LIGHTLD ->
          failwith "Compilation of C code is not supported for this toolchain"
    in
    if !verbose >= 1 || !dry_mode then Printf.printf "+ %s\n%!" cmd;
    if (Sys.command cmd <> 0) then failwith "Error while compiling";
    tmp_obj
  end else
    file

let dump fn =
  let fn = find_file fn in
  Printf.printf "*** %s:\n" fn;
  match Lib.read fn with
  | `Lib (objs,imports) ->
      List.iter
	(fun (n,o) ->
	  Printf.printf "** %s(%s):\n" fn n;
	  Coff.dump o
	)
	objs;
      List.iter
	(fun (s,i) -> Printf.printf "** import: %s (%i)\n" s i)
	imports
  | `Obj o ->
      Coff.dump o

let all_files () =
  let files = List.rev (List.map compile_if_needed !files) in
  let f = Filename.concat flexdir in
  let tc = match !toolchain with
  | `MSVC -> "msvc.obj"
  | `MSVC64 -> "msvc64.obj"
  | `CYGWIN -> "cygwin.o"
  | `MINGW64 -> "mingw64.o"
  | `MINGW | `LIGHTLD -> "mingw.o" in
  if !exe_mode <> `DLL then
    if !add_flexdll_obj then f ("flexdll_" ^ tc) :: files
    else files
  else
    if !noentry then files
    else f ("flexdll_initer_" ^ tc) :: files

let main () =
  parse_cmdline ();
  setup_toolchain ();

  use_cygpath :=
    begin
      match !toolchain, !cygpath_arg with
      | _, `Yes -> true
      | _, `No -> false
      | (`MINGW|`MINGW64|`CYGWIN), `None ->
          begin match Sys.os_type with
          | "Unix" | "Cygwin" ->
              Sys.command "cygpath -S 2>/dev/null >/dev/null" = 0
          | "Win32" ->
              Sys.command "cygpath -S 2>NUL >NUL" = 0
          | _ -> assert false
          end
      | (`MSVC|`MSVC64|`LIGHTLD), `None -> false
    end;


  if !verbose >= 2 then (
    Printf.printf "** Use cygpath: %b\n" !use_cygpath;
    Printf.printf "** Search path:\n";
    List.iter print_endline !search_path;
    if !use_default_libs then begin
      Printf.printf "** Default libraries:\n";
      List.iter print_endline !default_libs;
    end
   );
  let files = all_files () in
  match !mode with
  | `DUMP -> List.iter dump files
  | `NORMAL ->
      build_dll !exe_mode !output_file files !exts
        (String.concat " " (List.map Filename.quote (List.rev !extra_args)))
  | `PATCH ->
      patch_output !output_file

let () =
  try main ()
  with
    | Failure s ->
	Printf.eprintf "** Fatal error: %s\n" s;
	exit 2
    | Invalid_argument s ->
	Printf.eprintf "** Fatal error: invalid argument (%s)\n" s;
	exit 2
    | Arg.Help s ->
        Printf.printf "%s\n%s\n" s footer;
        exit 0
    | Arg.Bad s ->
        Printf.eprintf "%s\n%s\n" s footer;
        exit 2
    | exn ->
	Printf.eprintf "** Error: %s\n" (Printexc.to_string exn);
	exit 2
