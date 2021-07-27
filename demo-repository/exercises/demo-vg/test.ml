open Test_lib
open Report

let () =
  set_result @@
  ast_sanity_check code_ast @@ fun () ->
  [ Section
      ([ Text "Function:" ; Code "plus" ],
        test_function_2_against_solution
          [%ty : int -> int -> int ] "plus"
          [ (1, 1) ; (2, 2) ; (10, -10) ]) ;
    Section
      ([ Text "Function:" ; Code "vg" ], test_vg_against_solution "vg") ]
