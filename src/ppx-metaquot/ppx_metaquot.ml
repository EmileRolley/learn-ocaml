(*  This file is part of the ppx_tools package.  It is released  *)
(*  under the terms of the MIT license (see LICENSE file).       *)
(*  Copyright 2013  Alain Frisch and LexiFi                      *)

(* A -ppx rewriter to be used to write Parsetree-generating code
   (including other -ppx rewriters) using concrete syntax.

   We support the following extensions in expression position:

   [%expr ...]  maps to code which creates the expression represented by ...
   [%pat? ...] maps to code which creates the pattern represented by ...
   [%str ...] maps to code which creates the structure represented by ...
   [%stri ...] maps to code which creates the structure item represented by ...
   [%sig: ...] maps to code which creates the signature represented by ...
   [%sigi: ...] maps to code which creates the signature item represented by ...
   [%type: ...] maps to code which creates the core type represented by ...

   Quoted code can refer to expressions representing AST fragments,
   using the following extensions:

     [%e ...] where ... is an expression of type Parsetree.expression
     [%t ...] where ... is an expression of type Parsetree.core_type
     [%p ...] where ... is an expression of type Parsetree.pattern
     [%%s ...] where ... is an expression of type Parsetree.structure
               or Parsetree.signature depending on the context.


   All locations generated by the meta quotation are by default set
   to [Ast_helper.default_loc].  This can be overriden by providing a custom
   expression which will be inserted whereever a location is required
   in the generated AST.  This expression can be specified globally
   (for the current structure) as a structure item attribute:

     ;;[@@metaloc ...]

   or locally for the scope of an expression:

     e [@metaloc ...]



   Support is also provided to use concrete syntax in pattern
   position.  The location and attribute fields are currently ignored
   by patterns generated from meta quotations.

   We support the following extensions in pattern position:

   [%expr ...]  maps to code which creates the expression represented by ...
   [%pat? ...] maps to code which creates the pattern represented by ...
   [%str ...] maps to code which creates the structure represented by ...
   [%type: ...] maps to code which creates the core type represented by ...

   Quoted code can refer to expressions representing AST fragments,
   using the following extensions:

     [%e? ...] where ... is a pattern of type Parsetree.expression
     [%t? ...] where ... is a pattern of type Parsetree.core_type
     [%p? ...] where ... is a pattern of type Parsetree.pattern

*)

module Main : sig val expander: string list -> Ast_mapper.mapper end = struct
  open Asttypes
  open Parsetree
  open Ast_helper
  open Ast_convenience

  let prefix ty s =
    let open Longident in
    match Longident.parse ty [@ocaml.warning "-3"] with
    | Ldot(m, _) -> String.concat "." (Longident.flatten m) ^ "." ^ s
    | _ -> s

  let append ?loc ?attrs e e' =
    let fn = Location.mknoloc (Longident.(Ldot (Lident "List", "append"))) in
    Exp.apply ?loc ?attrs (Exp.ident fn) [Nolabel, e; Nolabel, e']

  class exp_builder =
    object
      method record ty x = record (List.map (fun (l, e) -> prefix ty l, e) x)
      method constr ty (c, args) = constr (prefix ty c) args
      method list l = list l
      method tuple l = tuple l
      method int i = int i
      method string s = str s
      method char c = char c
      method int32 x = Exp.constant (Const.int32 x)
      method int64 x = Exp.constant (Const.int64 x)
      method nativeint x = Exp.constant (Const.nativeint x)
    end

  class pat_builder =
    object
      method record ty x = precord ~closed:Closed (List.map (fun (l, e) -> prefix ty l, e) x)
      method constr ty (c, args) = pconstr (prefix ty c) args
      method list l = plist l
      method tuple l = ptuple l
      method int i = pint i
      method string s = pstr s
      method char c = pchar c
      method int32 x = Pat.constant (Const.int32 x)
      method int64 x = Pat.constant (Const.int64 x)
      method nativeint x = Pat.constant (Const.nativeint x)
    end


  let get_exp loc = function
    | PStr [ {pstr_desc=Pstr_eval (e, _); _} ] -> e
    | _ ->
        let report = Location.error ~loc "Expression expected." in
        Location.print_report Format.err_formatter report;
        exit 2

  let get_typ loc = function
    | PTyp t -> t
    | _ ->
        let report = Location.error ~loc "Type expected." in
        Location.print_report Format.err_formatter report;
        exit 2

  let get_pat loc = function
    | PPat (t, None) -> t
    | _ ->
        let report = Location.error ~loc "Pattern expected." in
        Location.print_report Format.err_formatter report;
        exit 2

  let exp_lifter loc map =
    let map = map.Ast_mapper.expr map in
    object
      inherit [_] Ast_lifter.lifter as super
      inherit exp_builder

      (* Special support for location in the generated AST *)
      method! lift_Location_t _ = loc

      (* Support for antiquotations *)
      method! lift_Parsetree_expression = function
        | {pexp_desc=Pexp_extension({txt="e";loc}, e); _} -> map (get_exp loc e)
        | x -> super # lift_Parsetree_expression x

      method! lift_Parsetree_pattern = function
        | {ppat_desc=Ppat_extension({txt="p";loc}, e); _} -> map (get_exp loc e)
        | x -> super # lift_Parsetree_pattern x

      method! lift_Parsetree_structure str =
        List.fold_right
          (function
           | {pstr_desc=Pstr_extension(({txt="s";loc}, e), _); _} ->
               append (get_exp loc e)
           | x ->
               cons (super # lift_Parsetree_structure_item x))
          str (nil ())

      method! lift_Parsetree_signature sign =
        List.fold_right
          (function
           | {psig_desc=Psig_extension(({txt="s";loc}, e), _); _} ->
               append (get_exp loc e)
           | x ->
               cons (super # lift_Parsetree_signature_item x))
          sign (nil ())

      method! lift_Parsetree_core_type = function
        | {ptyp_desc=Ptyp_extension({txt="t";loc}, e); _} ->map (get_exp loc e)
        | x -> super # lift_Parsetree_core_type x
    end

  let pat_lifter map =
    let map = map.Ast_mapper.pat map in
    object
      inherit [_] Ast_lifter.lifter as super
      inherit pat_builder as builder

      (* Special support for location and attributes in the generated AST *)
      method! lift_Location_t _ = Pat.any ()
      method! lift_Parsetree_attributes _ = Pat.any ()
      method! record n fields =
        let fields =
          List.map (fun (name, pat) ->
              match name with
              | "pexp_loc_stack" | "ppat_loc_stack" | "ptyp_loc_stack" ->
                 name, Pat.any ()
              | _ -> name, pat) fields
        in
        builder#record n fields

      (* Support for antiquotations *)
      method! lift_Parsetree_expression = function
        | {pexp_desc=Pexp_extension({txt="e";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_expression x

      method! lift_Parsetree_pattern = function
        | {ppat_desc=Ppat_extension({txt="p";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_pattern x

      method! lift_Parsetree_core_type = function
        | {ptyp_desc=Ptyp_extension({txt="t";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_core_type x
    end

  let loc = ref (app (evar "Stdlib.!") [evar "Ast_helper.default_loc"])

  let handle_attr = function
    | {attr_name={txt="metaloc";loc=l}; attr_payload=e; _} -> loc := get_exp l e
    | _ -> ()

  let with_loc ?(attrs = []) f =
    let old_loc = !loc in
    List.iter handle_attr attrs;
    let r = f () in
    loc := old_loc;
    r

  (* ------ <edited for learn-ocaml> ------ *)
  let ty_of this cty =
    let obj_id =
      Location.mknoloc
        Longident.(Ldot (Lident "Ty", "repr")) in
    let ty_id =
      Location.mknoloc
        Longident.(Ldot (Lident "Ty", "ty")) in
    let tyexpr =
      ((exp_lifter !loc this) # lift_Parsetree_core_type cty) in
    Exp.constraint_
      (Exp.apply
         (Exp.ident obj_id)
         [Nolabel, tyexpr])
      (Typ.constr ty_id [cty])

  let fun_ty_of this l e =
    (* Naming convention: ty:=Ty.ty, cty:=core_type, ety:=expression *)
    let glob_cty = get_typ l e in
    match glob_cty with
    | { Parsetree.ptyp_desc = Parsetree.Ptyp_arrow (_, arg0, next) ; _ } ->
       (* OK: The type expression is an arrow type *)
       (* Recursion over [core_type]s: *)
       let rec get_fun_ty_of arg0 next =
         match next with
         | { Parsetree.ptyp_desc = Parsetree.Ptyp_arrow (_, arg', next') ; _ } ->
            let fun_ty_next, ucty, ret = get_fun_ty_of arg' next' in
            (* Arg_ty (arg0, fun_ty_next) : (('a -> 'b -> 'c) Ty.ty, 'a -> 'b -> 'd, 'r) *)
            let cons_arg_id = Location.mknoloc Longident.(Ldot (Lident "Fun_ty", "arg_ty")) in
            let arg0_ety = ty_of this arg0 in
            let ucty = Typ.arrow Nolabel arg0 ucty in
            (Exp.apply
               (Exp.apply
                  (Exp.ident cons_arg_id)
                  [Nolabel, arg0_ety])
               [Nolabel, fun_ty_next],
             ucty, ret)
         | _ ->
            (* Last_ty (arg0, next) : (('a -> 'r) Ty.ty, 'a -> unit, 'r) fun_ty *)
            let cons_last_id = Location.mknoloc Longident.(Ldot (Lident "Fun_ty", "last_ty")) in
            let arg0_ety = ty_of this arg0 in
            let next_ety = ty_of this next in
            let unit_id = Location.mknoloc (Longident.Lident "unit") in
            let unit_cty = Typ.constr unit_id [] in
            let ucty = Typ.arrow Nolabel arg0 unit_cty in
            (Exp.apply
               (Exp.apply
                  (Exp.ident cons_last_id)
                  [Nolabel, arg0_ety])
               [Nolabel, next_ety],
             ucty, next)
       in
       (* Main branch *)
       let fun_ty_next, ucty, ret = get_fun_ty_of arg0 next in
       (* fun_ty_next : (('a -> 'b -> 'r) Ty.ty, 'a -> 'b -> unit, 'r) [typecast] *)
       let fun_ty_id = Location.mknoloc Longident.(Ldot (Lident "Fun_ty", "fun_ty")) in
       let ty_id = Location.mknoloc Longident.(Ldot (Lident "Ty", "ty")) in
       let glob_cty_ty = Typ.constr ty_id [glob_cty] in
       Exp.constraint_
         fun_ty_next
         (Typ.constr fun_ty_id [glob_cty_ty; ucty; ret])
    | _ -> invalid_arg "fun_ty_of: not an arrow type"

  let printable_of this e =
    (* [%printable e] is a shortcut for
       [Test_lib.printable_fun e (Pprintast.string_of_expression [%expr e])] *)
    app (evar "Test_lib.printable_fun")
      [app (evar "Pprintast.string_of_expression")
        [(exp_lifter !loc this) # lift_Parsetree_expression e]; e]

  let code_of this e =
    (* [%code e] is a shortcut for [(Code.(e), Solution.(e), [%expr e])] *)
    let open_module name e =
      Exp.open_ (Opn.mk (Mod.ident (lid name))) e
    in
    tuple [open_module "Code" e;
           open_module "Solution" e;
           (exp_lifter !loc this) # lift_Parsetree_expression e]
  (* ------ </edited for learn-ocaml> ------ *)

  let expander _args =
    let open Ast_mapper in
    let super = default_mapper in
    let expr this e =
      with_loc ~attrs:e.pexp_attributes
        (fun () ->
           match e.pexp_desc with
           | Pexp_extension({txt="expr";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_expression (get_exp l e)
           | Pexp_extension({txt="pat";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_pattern (get_pat l e)
           | Pexp_extension({txt="str";_}, PStr e) ->
               (exp_lifter !loc this) # lift_Parsetree_structure e
           | Pexp_extension({txt="stri";_}, PStr [e]) ->
               (exp_lifter !loc this) # lift_Parsetree_structure_item e
           | Pexp_extension({txt="sig";_}, PSig e) ->
               (exp_lifter !loc this) # lift_Parsetree_signature e
           | Pexp_extension({txt="sigi";_}, PSig [e]) ->
               (exp_lifter !loc this) # lift_Parsetree_signature_item e
           | Pexp_extension({txt="type";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_core_type (get_typ l e)
(* ------ <edited for learn-ocaml> ------ *)
           | Pexp_extension({txt="ty";loc=l}, e) ->
              let ty = get_typ l e in
              ty_of this ty
           | Pexp_extension({txt="funty";loc=l}, e) ->
              fun_ty_of this l e
           | Pexp_extension({txt="printable";loc=l}, e) ->
              printable_of this (get_exp l e)
           | Pexp_extension({txt="code";loc=l}, e) ->
              code_of this (get_exp l e)
(* ------ </edited for learn-ocaml> ------ *)
           | _ ->
               super.expr this e
        )
    and pat this p =
      with_loc ~attrs:p.ppat_attributes
        (fun () ->
           match p.ppat_desc with
           | Ppat_extension({txt="expr";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_expression (get_exp l e)
           | Ppat_extension({txt="pat";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_pattern (get_pat l e)
           | Ppat_extension({txt="str";_}, PStr e) ->
               (pat_lifter this) # lift_Parsetree_structure e
           | Ppat_extension({txt="stri";_}, PStr [e]) ->
               (pat_lifter this) # lift_Parsetree_structure_item e
           | Ppat_extension({txt="sig";_}, PSig e) ->
               (pat_lifter this) # lift_Parsetree_signature e
           | Ppat_extension({txt="sigi";_}, PSig [e]) ->
               (pat_lifter this) # lift_Parsetree_signature_item e
           | Ppat_extension({txt="type";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_core_type (get_typ l e)
           | _ ->
               super.pat this p
        )
    and structure this l =
      with_loc
        (fun () -> super.structure this l)

    and structure_item this x =
      begin match x.pstr_desc with
      | Pstr_attribute x -> handle_attr x
      | _ -> ()
      end;
      super.structure_item this x

    and signature this l =
      with_loc
        (fun () -> super.signature this l)

    and signature_item this x =
      begin match x.psig_desc with
      | Psig_attribute x -> handle_attr x
      | _ -> ()
      end;
      super.signature_item this x

    in
    {super with expr; pat; structure; structure_item; signature; signature_item}
end

let expander = Main.expander
