#! /usr/bin/env racket
#lang racket

(require "utilities.rkt")
(require "interp-Lvar.rkt")
(require "interp-Cvar.rkt")
(require "interp-Lif.rkt")
(require "interp-Cif.rkt")
(require "interp.rkt")
(require "interp-Lwhile.rkt")
(require "interp-Cwhile.rkt")
(require "interp-Lvec.rkt")
(require "interp-Cvec.rkt")
(require "interp-Lfun.rkt")
(require "interp-Cfun.rkt")
(require "compiler.rkt")
(debug-level 1)
;; (AST-output-syntax 'concrete-syntax)

;; all the files in the tests/ directory with extension ".rkt".
(define all-tests
  (map (lambda (p) (car (string-split (path->string p) ".")))
       (filter (lambda (p)
                 (string=? (cadr (string-split (path->string p) ".")) "rkt"))
               (directory-list (build-path (current-directory) "tests")))))

(define (tests-for r)
  (map (lambda (p)
         (caddr (string-split p "_")))
       (filter
        (lambda (p)
          (string=? r (car (string-split p "_"))))
        all-tests)))

;; The following tests the intermediate-language outputs of the passes.
; (interp-tests "var" #f compiler-passes interp-Lvar "var_test" (tests-for "var"))
; (interp-tests "if" #f compiler-passes interp-Lif "cond_test" (tests-for "cond"))
; (interp-tests "if" #f compiler-passes interp-Lif "cond_test" (tests-for "cond"))
; (interp-tests "while" #f compiler-passes interp-Lwhile "while_test" (tests-for "while"))
; (interp-tests "tup" #f compiler-passes interp-Lvec "vectors_test" (tests-for "vectors"))
(interp-tests "fun" #f compiler-passes interp-Lfun "functions_test" (tests-for "functions"))


;; Uncomment the following when all the passes are complete to
;; test the final x86 code.
;(compiler-tests "var" #f compiler-passes "var_test" (tests-for "var"))



