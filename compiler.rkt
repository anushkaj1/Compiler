#lang racket

(require racket/match racket/list racket/set graph)
(require "interp-Lif.rkt")
(require "interp-Cif.rkt")
(require "type-check-Lif.rkt")
(require "type-check-Cif.rkt")
(require "utilities.rkt")
(require "interp.rkt")
(require "interp-Lint.rkt")
(require "interp-Lvar.rkt")
(require "interp-Cvar.rkt")
(require "type-check-Lvar.rkt")
(require "type-check-Cvar.rkt")
(require "interp-Lwhile.rkt")
(require "interp-Cwhile.rkt")
(require "type-check-Lwhile.rkt")
(require "type-check-Cwhile.rkt")
(require "interp-Lvec.rkt")
(require "interp-Lvec-prime.rkt")
(require "interp-Cvec.rkt")
(require "type-check-Lvec.rkt")
(require "type-check-Cvec.rkt")
(require "interp-Lfun.rkt")
(require "interp-Lfun-prime.rkt")
(require "interp-Cfun.rkt")
(require "type-check-Lfun.rkt")
(require "type-check-Cfun.rkt")
(require "multigraph.rkt")
(provide (all-defined-out))

(define basic-blocks '())

(define (remove-and-or e)
  (print e)
  (match e
    [(Void) (Void)]
    [(or (Bool _) (Int _) (Var _)) e]
    [(If e1 e2 e3) (If (remove-and-or e1) (remove-and-or e2) (remove-and-or e3))]
    [(Prim 'read '()) (Prim 'read '())]
    [(Prim 'and (list e1 e2)) (If (remove-and-or e1) (remove-and-or e2) (Bool #f))]
    [(Prim 'or (list e1 e2)) (If (remove-and-or e1) (Bool #t) (remove-and-or e2))]
    [(Prim op es) (Prim op (for/list ([e es]) (remove-and-or e)))]
    [(Let x ex body) (Let x (remove-and-or ex) (remove-and-or body))]
    [(SetBang var rhs) (SetBang var (remove-and-or rhs))]
    [(Begin body rhs) (Begin (for/list ([e body]) (remove-and-or e)) (remove-and-or rhs))]
    [(WhileLoop cnd ex) (WhileLoop (remove-and-or cnd) (remove-and-or ex))]
    [(Apply func inputs) (Apply func (for/list ([ex inputs]) (remove-and-or ex)))]
    [(Def var types rettype info ret) (Def var types rettype info (remove-and-or ret))]))

(define (shrink p)
  (match p
    [(Program info body) (Program info (remove-and-or body))]
    [(ProgramDefsExp info defs ret) (ProgramDefs info 
                                      (append 
                                        (for/list ([def defs]) (remove-and-or def))
                                        (list (Def 'main '() 'Integer '() (remove-and-or ret)))))]))


(define (uniquify-exp env)
  (lambda (e)
    (match e
      [(Void) (Void)]
      [(Var x) (Var (dict-ref env x))]
      [(or (Int _) (Bool _)) e]
      [(Let x e body) (let [(x-uniq (gensym))]
                        (let [(new-uniq-pass (uniquify-exp (dict-set env x x-uniq)))]
                          (Let x-uniq (new-uniq-pass e) (new-uniq-pass body))))]
      [(If e1 e2 e3) (If ((uniquify-exp env) e1) ((uniquify-exp env) e2) ((uniquify-exp env) e3))]
      [(Prim op es)
       (Prim op (for/list ([e es]) ((uniquify-exp env) e)))]
      [(SetBang var rhs) (SetBang (dict-ref env var) ((uniquify-exp env) rhs))]
      [(Begin body rhs) (Begin (for/list ([e body]) ((uniquify-exp env) e)) ((uniquify-exp env) rhs))]
      [(WhileLoop cnd e) (WhileLoop ((uniquify-exp env) cnd) ((uniquify-exp env) e))]
      [(Apply func inputs) (Apply func (for/list ([ex inputs]) ((uniquify-exp env) ex)))]
      [(Def var types rettype info ret) (let ([types-uniq (foldr 
                                                          (lambda (curr typ)
                                                            (cons (list (gensym) ': (car (cdr (cdr curr)))) typ))
                                                          '()
                                                          types)])
                                          (let ([new-uniq-pass (uniquify-exp (foldr 
                                                                  (lambda (curr curr-uniq new-env)
                                                                    (dict-set new-env (car curr) (car curr-uniq)))
                                                                  env
                                                                  types
                                                                  types-uniq))])
                                                (Def var types-uniq rettype info (new-uniq-pass ret))))])))

;; uniquify : Lvar -> Lvar
(define (uniquify p)
  (match p
    [(Program info e) (Program info ((uniquify-exp '()) e))]
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) ((uniquify-exp '()) def)))]))

(define (reveal e)
  (match e
    [(or (Int _) (Var _) (Bool _) (Void)) e]
    [(Prim op es) (Prim op (for/list ([ex es]) (reveal ex)))]
    [(Let x rhs body) (Let x (reveal rhs) (reveal body))]
    [(If cnd thn els) (If (reveal cnd) (reveal thn) (reveal els))]
    [(SetBang x rhs) (SetBang x (reveal rhs))]
    [(Begin body rhs) (Begin (for/list ([ex body]) (reveal ex)) (reveal rhs))]
    [(WhileLoop cnd body) (WhileLoop (reveal cnd) (reveal body))]
    [(Apply (Var f) inputs) (Apply (FunRef f (length inputs)) inputs)]
    [(Def var types rettype info ret) (Def var types rettype info (reveal ret))]))

(define (reveal-functions p)
  (match p
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (reveal def)))]))

;; ------------------------------ LIMIT FUNCTIONS ---------------------------------------

; returns list of elements that go in one tuple as the 6th argument
(define (get-tup-elems types)
  (if (< (length types) 7)
    '()
    (let ([i 0]) 
      (reverse (foldl
                    (lambda (elem tup-elems)
                      (set! i (+ i 1))
                      (if (< i 6) tup-elems (cons (car elem) tup-elems)))
                    '() types)))))

; lower and upper both inclusive
; indexing starts from 1
(define (get-elems-in-range l lower upper)
  (let ([i 0])
    (reverse (foldl
                (lambda (elem lst)
                  (set! i (+ i 1))
                  (if (and (>= i lower) (<= i upper))
                    (cons elem lst)
                    lst))
                '() l))))

; returns new types list
(define (generate-types types tup-name)
  (if (< (length types) 7) 
    types
    (let ([i 0]) (let ([new-types (reverse (foldl
                                                (lambda (elem lst)
                                                  (set! i (+ i 1))
                                                  (if (< i 6)
                                                    (cons elem lst) lst))
                                                '() types))])
                    (set! i 0)
                    (append new-types (list (list tup-name ': (reverse (foldl
                                                                (lambda (elem tup)
                                                                  (set! i (+ i 1))
                                                                  (if (< i 6)
                                                                    tup
                                                                    (cons (car (cdr (cdr elem))) tup)))
                                                                '(Vector) types)))))))))

(define (index-of elem lst)
  (let ([i -1])
    (foldl
      (lambda (x out)
        (set! i (+ i 1))
        (if (eq? x elem) i out))
      -1 lst)))

; updates occurrences of tuple elems
(define (update-variables e types tup-name tup-elems)
  (match e
    [(Var var) (match (member var tup-elems)
                  [#f (Var var)]
                  [else (Prim 'vector-ref (list (Var tup-name) (Int (index-of var tup-elems))))])]
    [(or (Int _) (Bool _) (Void) (FunRef _ _)) e]
    [(Prim op es) (Prim op (for/list ([ex es]) (update-variables ex types tup-name tup-elems)))]
    [(Let x rhs body) (Let x (update-variables rhs types tup-name tup-elems)
                        (update-variables body types tup-name tup-elems))]
    [(If cnd thn els) (If (update-variables cnd types tup-name tup-elems)
                        (update-variables thn types tup-name tup-elems)
                        (update-variables els types tup-name tup-elems))]
    [(SetBang x rhs) (SetBang x (update-variables rhs types tup-name tup-elems))]
    [(Begin body rhs) (Begin (for/list ([ex body]) (update-variables ex types tup-name tup-elems))
                        (update-variables rhs types tup-name tup-elems))]
    [(WhileLoop cnd body) (WhileLoop (update-variables cnd types tup-name tup-elems)
                            (update-variables body types tup-name tup-elems))]
    [(Apply f es) (if (< (length es) 7)
                      (Apply f es)
                      (let ([arg6 (gensym 'vec)]) 
                        (Let arg6 (Prim 'vector (get-elems-in-range es 6 (length es)))
                          (Apply f (append (get-elems-in-range es 1 5) (list (Var arg6)))))))]
    [(Def _ _ _ _ _) (limit e)]))

(define (limit def)
  (match def
    [(Def var types rettype info ret)
      (let ([tup-name (gensym)])
        (Def var (generate-types types tup-name) rettype info (update-variables ret types tup-name (get-tup-elems types))))]))

(define (limit-functions p)
  (match p
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (limit def)))]))

;; ------------------------ END OF LIMIT FUNCTIONS --------------------------------------

(define (collect-set! e) 
  (match e
    [(Void) (set)]
    [(Var x) (set)] 
    [(Int n) (set)] 
    [(Bool b) (set)]
    [(Let x rhs body) (set-union (collect-set! rhs) (collect-set! body))]
    [(SetBang var rhs) (set-union (set var) (collect-set! rhs))]
    [(If cnd thn els) (set-union (collect-set! cnd) (collect-set! thn) (collect-set! els))]
    [(Begin body rhs) (set-union 
                        (foldr 
                          (lambda (es set!-vars)
                            (set-union (collect-set! es) set!-vars))
                          (collect-set! rhs) body)
                        (collect-set! rhs))]
    [(WhileLoop cnd e) (set-union (collect-set! cnd) (collect-set! e))]
    [(Prim op es) (foldr 
                    (lambda (sub-es set!-vars)
                      (set-union (collect-set! sub-es) set!-vars))
                    (set) es)]
    [(Apply f es) (foldr 
                    (lambda (sub-es set!-vars)
                      (set-union (collect-set! sub-es) set!-vars))
                    (set) es)]
    [(Def f types rettype info body) (collect-set! body)]))

(define (uncover-get!-exp set!-vars e) 
  (match e
    [(Void) e]
    [(Var x)
      (if (set-member? set!-vars x)
        (GetBang x)
            (Var x))]
    [(or (Int _) (Bool _)) e]
    [(Prim op es) (Prim op (for/list ([e es]) (uncover-get!-exp set!-vars e)))]
    [(Let x rhs body) (Let x (uncover-get!-exp set!-vars rhs) (uncover-get!-exp set!-vars body))]
    [(If e1 e2 e3) (If (uncover-get!-exp set!-vars e1) (uncover-get!-exp set!-vars e2) (uncover-get!-exp set!-vars e3))]
    [(SetBang var rhs) (SetBang var (uncover-get!-exp set!-vars rhs))]
    [(Begin body rhs) (Begin (for/list ([e body]) (uncover-get!-exp set!-vars e)) (uncover-get!-exp set!-vars rhs))]
    [(WhileLoop cnd e) (WhileLoop (uncover-get!-exp set!-vars cnd) (uncover-get!-exp set!-vars e))]
    [(Apply f es) (Apply f (for/list ([ex es]) (uncover-get!-exp set!-vars ex)))]
    [(Def f types rettype info body) (Def f types rettype info (uncover-get!-exp set!-vars body))]))

(define (uncover-get! p)
  (match p
    [(Program info body) (Program info (uncover-get!-exp (collect-set! body) body))]
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (uncover-get!-exp (collect-set! def) def)))]))

(define (expose-wrap es type)
  (let ([x (foldr 
            (lambda (elem xlst)
              (cons (gensym "v") xlst))
            '() es)])
    (foldr 
      (lambda (x-elem e-elem vec)
        (Let x-elem e-elem vec))
      (expose-has-type x type)
      x
      es)))

(define (expose-has-type es type)
  (Let (gensym "_") (If (Prim '< 
                          (list (Prim '+ 
                                  (list (GlobalValue 'free_ptr)
                                    (Int (+ 8 (* 8 (length es))))))
                                  (GlobalValue 'fromspace_end)))
                          (Void)
                          (Collect (+ 8 (* 8 (length es)))))
    (let ([v (gensym "vecinit")])
      (let ([i -1])
        (Let v (Allocate (length es) type)
          (foldl 
            (lambda (x ex)
              (set! i (+ i 1))
              (Let (gensym "_") 
                (Prim 'vector-set! (list (Var v) (Int i) (expose-allocate x)))
                ex))
             (Var v) es))))))

(define (expose-allocate e)
  (match e
    [(HasType (Prim 'vector es) type) (expose-has-type es type)]
    [(or (Int _) (Var _) (Bool _) (Void) (GetBang _)) e]
    [(Prim op es) (Prim op (for/list [(e es)] (expose-allocate e)))]
    [(Let x rhs body) (Let x (expose-allocate rhs) (expose-allocate body))]
    [(If e1 e2 e3) (If (expose-allocate e1) (expose-allocate e2) (expose-allocate e3))]
    [(SetBang x rhs) (SetBang x (expose-allocate rhs))]
    [(Begin body rhs) (Begin (for/list [(e body)] (expose-allocate e)) (expose-allocate rhs))]
    [(WhileLoop cnd body) (WhileLoop (expose-allocate cnd) (expose-allocate body))]
    [(Apply f es) (Apply f (for/list [(e es)] (expose-allocate e)))]))

(define (expose-allocation p)
  (match p
    [(Program info body) (Program info (expose-allocate body))]
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (match def
                                                                        [(Def f types rettype info body)
                                                                          (Def f types rettype info (expose-allocate body))])))]))

(define (atomize env e)
  (match e
    [(Apply f es) (let ([func (gensym 'f)]) (let ([mapping (make-hash)]) 
                    (let ([new-es (foldr 
                      (lambda (elem lst)
                        (match elem
                          [(or (Int _) (Var _) (Bool _) (Void)) (cons elem lst)]
                          [(GetBang var) (cons (Var var) lst)]
                          [else (let ([x (gensym)]) (dict-set! mapping (Var x) elem) (cons (Var x) lst))]))
                      '() es)])
                      (foldr 
                        (lambda (elem ins)
                          (let ([x (dict-ref mapping elem #f)])
                            (match x
                              [#f ins]
                              [else (match elem 
                                      [(Var y) (Let y ((rco-exp env) x) ins)])])))
                        (Let func f (Apply (Var func) new-es))
                        new-es))))]))

(define (rco-exp env)
  (lambda (e)
    (match e
      [(Begin body (GetBang x)) (let [(y ((rco-atom env) x))] (Let y (Begin (for/list ([e body]) ((rco-exp env) e)) (Var x)) (Var y)))]
      [(Begin body rhs) (Begin (for/list ([e body]) ((rco-exp env) e)) ((rco-exp env) rhs))]
      [(SetBang var rhs) (SetBang var ((rco-exp env) rhs))]
      [(GetBang var) (Var var)]
      [(WhileLoop cnd e) (WhileLoop ((rco-exp env) cnd) ((rco-exp env) e))]
      [(Let x e body) (Let x ((rco-exp env) e) ((rco-exp env) body))]
      [(or (Int _) (Var _) (Bool _) (Void) (FunRef _ _)) e]
      [(Prim 'read '()) (Prim 'read '())]
      [(Prim op (list (or (Int _) (Var _) (Bool _)))) e]
      [(Prim op (list (or (Int _) (Var _) (Bool _)) (or (Var _) (Int _) (Bool _)))) e]
      [(Prim op (list e2)) (let [(x ((rco-atom env) e2))] (Let x ((rco-exp env) e2) (Prim op (list (Var x)))))]
      [(Prim op (list e1 e2)) #:when (or (Int? e1) (Var? e1) (Bool? e1) (Void? e1)) (let [(x ((rco-atom env) e2))] (Let x ((rco-exp env) e2) ((rco-exp env) (Prim op (list e1 (Var x))))))]
      [(Prim op (list e1 e2)) #:when (or (Int? e2) (Var? e2) (Bool? e2) (Void? e2)) (let [(x ((rco-atom env) e1))] (Let x ((rco-exp env) e1) ((rco-exp env) (Prim op (list (Var x) e2)))))]
      [(Prim op (list e1 e2)) (let [(x ((rco-atom env) e1))] (let [(y ((rco-atom env) e2))] (Let x ((rco-exp env) e1) (Let y ((rco-exp env) e2) (Prim op (list (Var x) (Var y)))))))]
      [(If e1 e2 e3) (If ((rco-exp env) e1) ((rco-exp env) e2) ((rco-exp env) e3))]
      [(Collect _) e]
      [(Allocate _ _) e]
      [(GlobalValue _) e]
      [(Prim op (list e1 e2 e3)) 
        #:when (not (or (Int? e1) (Var? e1) (Bool? e1) (Void? e1)))
          (let [(x (gensym))]
            (Let x ((rco-exp env) e1)
              ((rco-exp env) (Prim op (list (Var x) e2 e3)))))]
      [(Prim op (list e1 e2 e3)) 
        #:when (not (or (Int? e2) (Var? e2) (Bool? e2) (Void? e2)))
          (let [(x (gensym))]
            (Let x ((rco-exp env) e2)
              ((rco-exp env) (Prim op (list e1 (Var x) e3)))))]
      [(Prim op (list e1 e2 e3)) 
        #:when (not (or (Int? e3) (Var? e3) (Bool? e3) (Void? e3)))
          (let [(x (gensym))]
            (Let x ((rco-exp env) e3)
              ((rco-exp env) (Prim op (list e1 e2 (Var x))))))]
      [(Prim op (list _ _ _)) e]
      [(Apply _ _) (atomize env e)])))

(define (rco-atom env)
  (lambda (e)
    (let [(x-uniq (gensym))] (dict-set env x-uniq e) x-uniq)))

;; remove-complex-opera* : Lvar -> Lvar^mon
(define (remove-complex-opera* p)
  (match p
    [(Program info e) (Program info ((rco-exp '()) e))]
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (match def
                                                                        [(Def f types rettype info body)
                                                                          (Def f types rettype info ((rco-exp '()) body))])))]))

(define (explicate_tail e)
  (match e
    [(or (Bool _) (Var _) (Int _) (Void) (Allocate _ _) (GlobalValue _)) (Return e)]
    [(Collect _) (Seq e (Return (Void)))]
    [(Let x rhs body) (explicate_assign rhs x (explicate_tail body))]
    [(SetBang x rhs) (explicate_assign rhs x (Return (Void)))]
    [(Prim op es) (Return (Prim op es))]
    [(If cnd thn els) (explicate_pred cnd (explicate_tail thn) (explicate_tail els))]
    [(Begin body rhs) (foldl 
                        (lambda (e tail)
                          (explicate_effect e tail))
                        (explicate_tail rhs) body)]
    [(Apply f es) (TailCall f es)]
    [else (error "explicate_tail unhandled case" e)]))

(define (create_block tail) 
  (match tail
    [(Goto label) (Goto label)] 
    [else 
      (let ([label (gensym 'block)])
        (set! basic-blocks (cons (cons label tail) basic-blocks)) 
        (Goto label))]))

(define (explicate_assign e x cont)
  (match e
    [(or (GlobalValue _) (Allocate _ _)) (Seq (Assign (Var x) e) cont)]
    [(or (Collect _) (Void)) (Seq (Assign (Var x) (Void)) cont)]
    [(Bool b) (Seq (Assign (Var x) (Bool b)) cont)]
    [(Var y) (Seq (Assign (Var x) (Var y)) cont)]
    [(Int n) (Seq (Assign (Var x) (Int n)) cont)]
    [(FunRef f n) (Seq (Assign (Var x) (FunRef f n)) cont)]
    [(Let y rhs body) (explicate_assign rhs y (explicate_assign body x cont))]
    [(Prim op es) (Seq (Assign (Var x) (Prim op es)) cont)]
    [(If e1 e2 e3) (let ([l1 (create_block cont)])
                     (explicate_pred e1
                                     (explicate_assign e2 x l1)
                                     (explicate_assign e3 x l1)))]
    [(Begin body rhs) (foldl 
                        (lambda (e tail)
                          (explicate_effect e tail))
                        (explicate_assign rhs x cont) body)]
    [(SetBang x rhs) (Seq (Assign (Var x) (rhs)) cont)]
    [(Apply f es) (Seq (Assign (Var x) (Call f es)) cont)]
    [else (error "explicate_assign unhandled case" e)]))

(define (explicate_let_in_if e thn els)
  (match e
    [(or (Bool _) (Int _) (Var _) (Void)) (explicate_pred e thn els)]
    [(Prim op es) (explicate_pred (Prim op es) thn els)]
    [(If _ _ _) (explicate_pred e thn els)]
    [(Let x rhs body) (explicate_assign rhs x (explicate_let_in_if body thn els))]
    [(Begin body rhs) (explicate_pred (Begin body rhs) thn els)]))

(define (explicate_pred cnd thn els) 
  (match cnd
    [(Var x) (IfStmt (Prim 'eq? (list (Var x) (Int 0))) 
                (create_block els) (create_block thn))]
    [(Int n) (IfStmt (Prim 'eq? (list (Int n) (Int 0))) 
                (create_block els) (create_block thn))]
    [(Let x rhs body) (explicate_assign rhs x (explicate_let_in_if body thn els))]
    [(Prim 'not (list e)) (explicate_pred e els thn)]
    [(Prim op es) ;#:when (or (eq? op 'eq?) (eq? op '<))
      (IfStmt (Prim op es) (create_block thn) (create_block els))]
    [(Bool b) (if b thn els)]
    [(If cnd^ thn^ els^) (explicate_pred cnd^ 
                          (create_block (explicate_pred thn^ thn els)) 
                          (create_block (explicate_pred els^ thn els)))]
    [(Begin body rhs) (foldl 
                        (lambda (e tail)
                          (explicate_effect e tail))
                        (explicate_pred rhs thn els) body)]
    [(Apply f es) (IfStmt (Call f es) (create_block thn) (create_block els))]
    [else (error "explicate_pred unhandled case" cnd)]))

(define (explicate_effect e tail)
  (match e
    [(or (Allocate _ _) (GlobalValue _) (Collect _)) (Seq e tail)]
    [(Begin body rhs) (foldl 
                        (lambda (e t)
                          (explicate_effect e t))
                        (explicate_effect rhs tail) body)]
    [(or (Bool _) (Int _) (Var _) (Void)) tail]
    [(Prim op es) tail]
    ; [(If cnd thn els) ]  ;need to complete
    [(Let x rhs body) (explicate_assign rhs x (explicate_effect body tail))]
    [(SetBang x rhs) (explicate_assign rhs x tail)]
    [(WhileLoop cnd body) (let ([label (gensym 'block)])
                            (begin (set! basic-blocks (cons 
                                                        (cons label 
                                                          (explicate_pred cnd 
                                                            (create_block (explicate_effect body (Goto label)))
                                                            (create_block tail))) 
                                                        basic-blocks))
                              (Goto label)))]))

(define (explicate-wrap body info)
  (let ([start (explicate_tail body)])
    (set! basic-blocks (cons (cons 'start start) basic-blocks))
    basic-blocks))

(define (explicate-wrap-def body info func)
  (set! basic-blocks '())
  (let ([start (explicate_tail body)])
    (set! basic-blocks (cons (cons (string->symbol (string-append (symbol->string func) "_start")) start) basic-blocks))
    basic-blocks))

;; explicate-control : Lvar^mon -> Cvar
(define (explicate-control p)
  (match p
    [(Program info body) (CProgram info (explicate-wrap body info))]
    [(ProgramDefs info defs) (ProgramDefs info (for/list ([def defs]) (match def
                                                                        [(Def f types rettype info body)
                                                                          (Def f types rettype info (explicate-wrap-def body info f))])))]))


(define (select_atm a)
  (match a
    [(Bool #t) (Imm 1)]
    [(Bool #f) (Imm 0)]
    [(Int n) (Imm n)]
    [(Var x) (Var x)]
    [(Reg reg) (Reg reg)]
    [(Void) (Imm 0)]
    [(Imm n) (Imm n)]
    [(GlobalValue x) (Global x)]
    [(FunRef f n) (Global f)]))

(define (type-mask t [mask 0])
    (match t
      [`(Vector) mask]
      [`(Vector (Vector . ,_)) (bitwise-ior mask 1)]
      [`(Vector ,_) mask]
      [`(Vector . ((Vector . ,_) . ,rest)) (type-mask `(Vector . ,rest) (arithmetic-shift (bitwise-ior mask 1) 1))]
      [`(Vector . (,t . ,rest)) (type-mask `(Vector . ,rest) (arithmetic-shift mask 1))]
      [else (error "Type Mask Error" t)]))

(define (find_tag len type)
  (bitwise-ior 1 (arithmetic-shift len 1) (arithmetic-shift (type-mask type) 7)))

(define arg-regs (list (Reg 'rdi) (Reg 'rsi) (Reg 'rdx) (Reg 'rcx) (Reg 'r8) (Reg 'r9)))

(define (select_stmt e num-params)
  (match e
    [(Prim 'read arg) (list (Callq 'read_int 0))]
    [(Assign x (Bool #t)) (list (Instr 'movq (list (Imm 1) (select_atm x))))]
    [(Assign x (Bool #f)) (list (Instr 'movq (list (Imm 0) (select_atm x))))]
    [(Assign x (Int n)) (list (Instr 'movq (list (Imm n) (select_atm x))))]
    [(Assign x (Var y)) (list (Instr 'movq (list (Var y) (select_atm x))))]
    [(Assign x (Void)) (list (Instr 'movq (list (Imm 0) (select_atm x))))]
    [(Assign x (GlobalValue label)) (list (Instr 'movq (list (Global label) (select_atm x))))]
    [(Assign x (Prim '- (list atm))) (list (Instr 'movq (list (select_atm atm) (select_atm x))) 
                                          (Instr 'negq (list (select_atm x))))]
    [(Assign x (Prim 'not (list x))) (list (Instr 'xorq (list (Imm 1) (select_atm x))))]
    [(Assign x (Prim 'not (list atm))) (list (Instr 'movq (list (select_atm atm) (select_atm x))) 
                                            (Instr 'xorq (list (Imm 1) (select_atm x))))]
    [(Assign x (Prim '+ (list atm1 atm2))) (list (Instr 'movq (list (select_atm atm1) (select_atm x))) 
                                                (Instr 'addq (list (select_atm atm2) (select_atm x))))]
    [(Assign x (Prim '- (list atm1 atm2))) (list (Instr 'movq (list (select_atm atm1) (select_atm x))) 
                                                (Instr 'subq (list (select_atm atm2) (select_atm x))))]
    [(Assign x (Prim 'read arg)) (list (Callq 'read_int 0) 
                                      (Instr 'movq (list (Reg 'rax) (select_atm x))))]
    [(Assign x (Prim 'eq? (list atm1 atm2))) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                (Instr 'sete (list (Reg 'al)))
                                                (Instr 'movzbq (list (Reg 'al) (select_atm x))))]
    [(Assign x (Prim '< (list atm1 atm2))) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                (Instr 'setl (list (Reg 'al)))
                                                (Instr 'movzbq (list (Reg 'al) (select_atm x))))]
    [(Assign x (Prim '<= (list atm1 atm2))) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                (Instr 'setle (list (Reg 'al)))
                                                (Instr 'movzbq (list (Reg 'al) (select_atm x))))]
    [(Assign x (Prim '> (list atm1 atm2))) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                (Instr 'setg (list (Reg 'al)))
                                                (Instr 'movzbq (list (Reg 'al) (select_atm x))))]
    [(Assign x (Prim '>= (list atm1 atm2))) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                (Instr 'setge (list (Reg 'al)))
                                                (Instr 'movzbq (list (Reg 'al) (select_atm x))))]
    [(Assign x (Prim 'vector-ref (list tup (Int n)))) (list (Instr 'movq (list (select_atm tup) (Reg 'r11)))
                                                          (Instr 'movq (list (Deref 'r11 (* 8 (+ n 1))) (select_atm x))))]
    [(Prim 'vector-set! (list tup (Int n) rhs)) (list (Instr 'movq (list (select_atm tup) (Reg 'r11)))
                                                    (Instr 'movq (list (select_atm rhs) (Deref 'r11 (* 8 (+ n 1))))))]
    [(Assign x (Prim 'vector-set! (list tup (Int n) rhs))) (list (Instr 'movq (list (select_atm tup) (Reg 'r11)))
                                                                (Instr 'movq (list (select_atm rhs) (Deref 'r11 (* 8 (+ n 1)))))
                                                                (Instr 'movq (list (Imm 0) (select_atm x))))]
    [(Assign x (Prim 'vector-length (list tup))) (list (Instr 'movq (list (select_atm tup) (Reg 'r11)))
                                                      (Instr 'movq (list (Deref 'r11 0) (Reg 'rax)))
                                                      (Instr 'andq (list (Imm 63) (Reg 'rax)))
                                                      (Instr 'sarq (list (Imm 1)  (Reg 'rax)))
                                                      (Instr 'movq (list (Reg 'rax) (select_atm x))))]
    [(Collect byte) (list (Instr 'movq (list (Reg 'r15) (Reg 'rdi)))
                        (Instr 'movq (list (Imm byte) (Reg 'rsi)))
                        (Callq 'collect 0))]
    [(Assign x (Allocate len type)) (list (Instr 'movq (list (Global 'free_ptr) (Reg 'r11)))
                                        (Instr 'addq (list (Imm (* 8 (+ len 1))) (Global 'free_ptr)))
                                        (Instr 'movq (list (Imm (find_tag len type)) (Deref 'r11 0)))
                                        (Instr 'movq (list (Reg 'r11) (select_atm x))))]
    [(Assign x (FunRef f n)) (list (Instr 'leaq (list (Global f) (select_atm x))))]
    [(Assign x (Call f args)) (append 
                                (let ([i -1]) 
                                  (foldl 
                                    (lambda (arg instrucs)
                                      (set! i (+ i 1))
                                      (cons (Instr 'movq (list (select_atm arg) (list-ref arg-regs i))) instrucs))
                                    '() args))
                                (list (IndirectCallq (select_atm f) num-params)
                                  (Instr 'movq (list (Reg 'rax) (select_atm x)))))]))


(define (select_tail e num-params)
  (match e
    [(IfStmt (Prim 'eq? (list atm1 atm2)) (Goto l1) (Goto l2)) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                                  (JmpIf 'e l1)
                                                                  (JmpIf 'l l2)
                                                                  (JmpIf 'g l2))]
    [(IfStmt (Prim '> (list atm1 atm2)) (Goto l1) (Goto l2)) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                                  (JmpIf 'g l1)
                                                                  (JmpIf 'le l2))]
    [(IfStmt (Prim '>= (list atm1 atm2)) (Goto l1) (Goto l2)) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                                  (JmpIf 'ge l1)
                                                                  (JmpIf 'l l2))]
    [(IfStmt (Prim '< (list atm1 atm2)) (Goto l1) (Goto l2)) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                                  (JmpIf 'l l1)
                                                                  (JmpIf 'ge l2))]
    [(IfStmt (Prim '<= (list atm1 atm2)) (Goto l1) (Goto l2)) (list (Instr 'cmpq (list (select_atm atm1) (select_atm atm2)))
                                                                  (JmpIf 'le l1)
                                                                  (JmpIf 'g l2))]
    [(Goto l) (list (Instr 'cmpq (list (Imm 1) (Imm 1)))
                  (JmpIf 'le l))]                                                                                                                                                                                                                                             
    [(Seq stmt tail) (append (select_stmt stmt num-params) (select_tail tail num-params))]
    [(Return ex) (append (select_stmt (Assign (Reg 'rax) ex) num-params) (list (Jmp 'conclusion)))]
    [(TailCall f args) (append 
                          (let ([i -1]) 
                            (foldl 
                              (lambda (arg instrucs)
                                (set! i (+ i 1))
                                (cons (Instr 'movq (list (select_atm arg) (list-ref arg-regs i))) instrucs))
                              '() args))
                            (list (TailJmp (select_atm f) num-params)))]))


(define (select-defs body func types num-params info)
  (let ([start (string->symbol (string-append (symbol->string func) "_start"))])
    ; (let ([regs (list (Reg 'rdi) (Reg 'rsi) (Reg 'rdx) (Reg 'rcx) (Reg 'r8) (Reg 'r9))])
      (let ([i -1])
        (let ([args (foldl 
                      (lambda (arg instrucs)
                        (set! i (+ i 1))
                        (cons (Instr 'movq (list (list-ref arg-regs i) (Var (car arg)))) instrucs))
                      '() types)])
          (foldr (lambda (block prog)
                    (cons `(,(car block) . ,(Block info 
                                              (if (eq? (car block) start)
                                                (append args (select_tail (cdr block) num-params))
                                                (select_tail (cdr block) num-params)))) prog))
                  '() body)))))

;; stack space
(define (assign-stack-space info)
  (cons (cons 'stack-space (* 16  (+ 1 (quotient (length (cdr (assoc 'locals-types info))) 2)))) info))

;; select-instructions : Cvar -> x86var
(define (select-instructions p)
  (match p
    [(CProgram info body) (X86Program (assign-stack-space info) (foldr (lambda (block prog)
                                                                          (cons `(,(car block) . ,(Block info (select_tail (cdr block) info))) prog))
                                                                        '() body))]
    [(ProgramDefs info defs) (X86ProgramDefs info (for/list ([def defs]) (match def
                                                                        [(Def f types rettype info body) 
                                                                          (Def f '() 'Integer (cons (cons 'num-params (length types)) (assign-stack-space info))
                                                                            (select-defs body f types (length types) info))])))]))

(define (patch_instr body)
  (foldr (lambda (inst lst)
           (match inst
             [(Instr instr (list (Deref 'rbp n1) (Deref 'rbp n2))) 
              (append (list (Instr 'movq (list (Deref 'rbp n1) (Reg 'rax))) (Instr instr (list (Reg 'rax) (Deref 'rbp n2)))) lst)]
             [(Instr instr (list (Imm n)))
              #:when (> n 2e16)
              (append (list (Instr 'movq (list (Imm n) (Reg 'rax))) (Instr instr (list (Reg 'rax)))) lst)]
             [(Instr instr (list (Imm n) atm))
              #:when (> n 2e16)
              (append (list (Instr 'movq (list (Imm n) (Reg 'rax))) (Instr instr (list (Reg 'rax) atm))) lst)]
             [(Instr instr (list atm (Imm n)))
              #:when (> n 2e16)
              (append (list (Instr 'movq (list (Imm n) (Reg 'rax))) (Instr instr (list atm (Reg 'rax)))) lst)]
             [else (cons inst lst)])) '() body))

;; patch-instructions : x86var -> x86int
(define (patch-instructions p)
   (match p
     [(X86Program info (list (cons 'start (Block bl-info body)))) (X86Program info (list (cons 'start (Block bl-info (patch_instr body)))))]))

;; check system and spit out the correct label
;; Discontinued.
(define (correct-label str)
  (string->uninterned-symbol (if (eq? (system-type 'os) 'macosx)
                                 (string-append "_" str)
                                 str)))
;; add prelude to the body
(define (preludify stack-space body)
  (append body (list `(main . ,(Block '() (list (Instr 'pushq (list (Reg 'rbp)))
                                                              (Instr 'movq (list (Reg 'rsp) (Reg 'rbp)))
                                                              (Instr 'subq (list (Imm stack-space) (Reg 'rsp)))
                                                              (Jmp 'start)))))))
;; add conclusion to the body
(define (concludify stack-space body)
  (append body (list `(conclusion . ,(Block '() (list (Instr 'addq (list (Imm stack-space) (Reg 'rsp)))
                                                                    (Instr 'popq (list (Reg 'rbp)))
                                                                    (Retq)))))))


;; prelude-and-conclusion : x86int -> x86int
(define (prelude-and-conclusion p)
  (match p
    [(X86Program info body) (let [(stack-space (cdr (assoc 'stack-space info)))]
                              (X86Program info
                                          (concludify stack-space
                                                     (preludify stack-space body))))]))


;; compute the set of locations read by an instruction
;; arg? -> (set)
(define (get-loc arg)
  (match arg
    [(Reg r) (set r)]
    [(Var x) (set x)]
    [(Imm m) (set)]))

(define caller-saved-regs (set 'rax 'rcx 'rdx 'rsi 'rdi 'r8 'r9 'r10 'r11))
(define arg-passing-regs '(rdi rsi rdx rcx r8 r9))

;; locations written by an instruction
;; Instr? -> set?
(define (write-locs instr)
  (match instr
    [(Instr q (list _ a)) #:when (member q (list 'addq 'subq)) (get-loc a)]
    [(Instr q (list a)) #:when (member q (list 'negq)) (get-loc a)] ;; ASSUMPTION: pushq popq are not reading the locations
    [(Instr 'movq (list _ a2)) (get-loc a2)]
    [(Retq) (set)]
    ([Callq _ _] caller-saved-regs) 
    ([Jmp _] (set)) ;; TODO
    ))

;; The locations that are live before a jmp should be the locations in
;; Lbefore at the target of the jump.  So, we recommend maintaining an
;; alist named label->live that maps each label to the Lbefore for the
;; first instruction in its block. For now the only jmp in a x86Var
;; program is the jump to the conclusion. (For example, see figure
;; 3.1.) The conclusion reads from rax and rsp, so the alist should
;; map conclusion to the set {rax, rsp}.

;; locations read by an instruction
;; Instr? -> set?
(define (read-locs instr)
  (match instr
    [(Instr q (list a1 a2)) #:when (member q (list 'addq 'subq)) (set-union (get-loc a1) (get-loc a2))]
    [(Instr q (list a)) #:when (member q (list 'negq)) (get-loc a)] ;; ASSUMPTION: pushq popq are not reading the locations
    [(Instr 'movq (list a1 a2)) (get-loc a1)]
    [(Retq) (set)]
    ([Callq _ arity] (list->set (drop-right arg-passing-regs (- (length arg-passing-regs) arity)))) 
    ([Jmp 'conclusion] (set 'rax 'rsp))
    ))

;; (Instr?, set?) -> set?
(define (live-after-k-1 instr live-after-k)
  (set-union (set-subtract live-after-k (write-locs instr)) (read-locs instr)))

;; returns a list of subsequences
;; (x1 x2 ... xn) -> ((x1 ... xn) (x2 ... xn) ... (xn))
;; list? -> [list?]
(define (sub-instr l)
  (build-list (length l) (lambda (x) (drop l x))))

;; ([Instr?], set?) -> [set?]
(define (instr-to-live-after instrs initial)
  (map (lambda (l-instr)
         (foldr live-after-k-1 initial l-instr)) (sub-instr instrs)))

(define (update-blocks Block-pair)
  (match Block-pair
    [(cons label (Block info instrs)) (cons label (Block (dict-set info 'live-after (instr-to-live-after instrs (set))) instrs))]))

;; TODO
(define (label-live Block-pair)
  (match Block-pair
    [(cons label (Block info instrs)) (cons label (instr-to-live-after instrs (set)))]))

(define (find-edge-list label tail)
  (foldl (lambda (instr edges)
            (cons (match instr
              [(JmpIf _ l) (label l)]
              [else null])))
        '() tail))

(define (create-cfg blocks)
  (tsort (transpose (make-multigraph (foldl (lambda (bl edges)
            (append (find-edge-list (car bl) (cdr bl))
                    edges))
        '() blocks)))))

(define (uncover-live p)
  (match p
    [(X86Program info Block-alist) (X86Program info (map update-blocks Block-alist))]))


(define (get-final arg)
  (match arg
    [(Reg r) r]
    [(Var x) x]
    [(Imm m) '()] ;; TODO
    ))

; register allocation
(define (find-edges live-after body)
  (foldr (lambda (live instr edges)
           (append (match instr
                     [(Instr 'movq (list s d)) (foldr (lambda (v lst)
                                                        (cond
                                                          [(and (not (equal? (get-final s) v)) (not (equal? (get-final d) v))) (cons (list v (get-final d)) lst)]
                                                          [else lst])) 
                                                      '() (set->list live))]
                     [(Callq _ _) (foldr (lambda (v lst)
                                           (append (list (list v 'rax) (list v 'rcx) (list v 'rdx) (list v 'rsi) 
                                                         (list v 'rdi) (list v 'r8) (list v 'r9) (list v 'r10) (list v 'r11)) 
                                                   lst)) 
                                         '() (set->list live))]
                     [(Instr 'pushq _) '()]
                     [(Instr _ (list s d)) (foldr (lambda (v lst)
                                                    (cond
                                                      [(not (equal? (get-final d) v)) (cons (list v (get-final d)) lst)]
                                                      [else lst]))
                                                  '() (set->list live))]
                     [(Instr _ (list d)) (foldr (lambda (v lst)
                                                  (cond
                                                    [(not (equal? (get-final d) v)) (cons (list v (get-final d)) lst)]
                                                    [else lst])) 
                                                '() (set->list live))]
                     [else '()]) edges))
         '() live-after body))

(define (interference-graph live-after body)
  (undirected-graph (set->list (list->set (find-edges live-after body)))))

(define (build-blocks body)
  (map (lambda (block)
         (match block
           [(cons x (Block info e)) (cons x (Block (dict-set info 'conflicts (interference-graph (cdr (assoc 'live-after info)) e)) e))]))
        body))

(define (build-interference p)
  (match p
    [(X86Program info body) (X86Program info (build-blocks body))]))

(define init-colors (hash 'rcx 0 'rdx 1 'rsi 2 'rdi 3 'r8 4 'r9 5 'r10 6 'rbx 7 'r12 8 'r13 9 'r14 10 'rax -1 'rsp -2 'rbp -3 'r11 -4 'r15 -5))
(define color-regs (hash 0 'rcx 1 'rdx 2 'rsi 3 'rdi 4 'r8 5 'r9 6 'r10 7 'rbx 8 'r12 9 'r13 10 'r14))


;; greedy
;; graph?, hash? -> [set?]
(define (compute-saturation-hash-count graph colors vars)
  (define saturation-hash (make-hash))
  (for-each (lambda (vertex)
              (let ((saturation-set (list->set (map (lambda (neighbor) (hash-ref colors neighbor))
                                                    (filter (lambda (neighbor) (hash-has-key? colors neighbor))
                                                            (get-neighbors graph vertex))))))
                (hash-set! saturation-hash vertex (set-count saturation-set))))
            vars)
  saturation-hash)

(define (key-with-highest-value hash-table)
  (car (let ((key-value-pairs (hash-map hash-table (lambda (key value) (cons key value)))))
         (foldl (lambda (pair current-best)
                  (if (or (not current-best) (> (cdr pair) (cdr current-best)))
                      pair
                      current-best))
                #f
                key-value-pairs))))

(define (remove-values small big)
  (filter (lambda (x) (not (member x small))) big))

;; lowest color not in adjacent
(define (lowest-color colors adjacent)
  (apply min (remove-values
              (map (lambda (register) (hash-ref colors register))
                   (filter (lambda (x) (hash-has-key? colors x)) adjacent))
              (build-list 100 values))))

(define (color-graph graph vars [colors init-colors])
  (if (eq? (length vars) 0) colors
      (let [(highest-satur-var (key-with-highest-value (compute-saturation-hash-count graph colors vars)))]
        (color-graph graph (remove highest-satur-var vars)
                     (hash-set colors highest-satur-var (lowest-color colors (get-neighbors graph highest-satur-var))))))
  )

;; take every variable
;; get color from color-graph
;; get color register (if in bounds)
;; else pass to assign stack

(define (assign-register list-vars color-graph)
  (define var-to-register-hash (make-hash))
  (for-each (lambda (var)
              (let ((color (hash-ref color-graph var)))
                (let ((register (hash-ref color-regs color)))
                  (hash-set! var-to-register-hash var (Reg register)))))
            list-vars)
  var-to-register-hash)

;; assign variables in list from info to a hash map with stack locations
(define (assign-stack list-vars var-register-hashmap)
  (let ([var-hashmap var-register-hashmap])
    (map (lambda (var id)
           (hash-set! var-hashmap (car var) (Deref 'rbp (- (* 8 (+ 1 id)))))
           ) list-vars (range (length list-vars)))
    var-hashmap))

;; take variables inside body and then replace them with their
;; corresponding entries in the hashmap
(define (replace-var body var-hashmap)
  (map (lambda (inst)
         (match inst
           [(Instr instr (list (Var x))) (Instr instr (list (hash-ref var-hashmap x)))]
           [(Instr instr (list (Var x) (Var y))) (Instr instr (list (hash-ref var-hashmap x) (hash-ref var-hashmap y)))]
           [(Instr instr (list (Var x) atm)) (Instr instr (list (hash-ref var-hashmap x) atm))]
           [(Instr instr (list atm (Var x))) (Instr instr (list atm (hash-ref var-hashmap x)))]
           [else inst])) body))

;; assign-homes : x86var -> x86var
(define (allocate-registers p)
  (match p
    [(X86Program info (list (cons 'start (Block bl-info body))))
     #:when (list? (assoc 'locals-types info))
     (let ([list-vars (map car (cdr (assoc 'locals-types bl-info)))])
       (X86Program info (list (cons 'start (Block bl-info (replace-var body (assign-register list-vars
                                                                                             (color-graph (cdr (assoc 'conflicts bl-info))
                                                                                                           list-vars))))))))]
    [else p]))

; (shrink (Program '() (If (Prim 'and (list (Bool #t) (Let 'x (Int 4) (Prim 'or (list (Var 'x) (Prim 'not (list (Bool #f)))))))) (Bool #t) (Bool #f))))
; (shrink (Program '() (If (Prim 'and `(,(Prim '- '((Int 5))) ,(Bool #f))) (Int 42) (Int 42))))


;; Define the compiler passes to be used by interp-tests and the grader
;; Note that your compiler file (the file that defines the passes)
;; must be named "compiler.rkt"
(define compiler-passes
  `(
    ; ("uniquify" ,uniquify ,interp-Lvar ,type-check-Lvar)
    ; ("remove complex opera*" ,remove-complex-opera* ,interp-Lvar ,type-check-Lvar)
    ; ("explicate control" ,explicate-control, interp-Cvar ,type-check-Cvar)
    ; ("instruction selection" ,select-instructions ,interp-x86-0)
    ; ;("assign homes" ,assign-homes ,interp-x86-0)
    ; ("uncover live" ,uncover-live ,interp-x86-0)
    ; ("build interference" ,build-interference ,interp-x86-0)
    ; ("allocate registers" ,allocate-registers ,interp-x86-0)
    ; ("patch instructions" ,patch-instructions ,interp-x86-0)
    ; ("prelude-and-conclusion" ,prelude-and-conclusion ,interp-x86-0)
    ; ("shrink" ,shrink ,interp-Lif ,type-check-Lif)
    ; ("uniquify" ,uniquify ,interp-Lif ,type-check-Lif)
    ; ("remove complex opera*" ,remove-complex-opera* ,interp-Lif ,type-check-Lif)
    ; ("explicate control" ,explicate-control ,interp-Cif ,type-check-Cif)
    ; ("instruction select" ,select-instructions ,interp-pseudo-x86-1)
    ; ("shrink" ,shrink ,interp-Lwhile ,type-check-Lwhile)
    ; ("uniquify" ,uniquify ,interp-Lwhile ,type-check-Lwhile)
    ; ("uncover get!" ,uncover-get! ,interp-Lwhile ,type-check-Lwhile)
    ; ("remove complex opera*" ,remove-complex-opera* ,interp-Lwhile ,type-check-Lwhile)
    ; ("explicate control" ,explicate-control ,interp-Cwhile ,type-check-Cwhile)
    ; ("instruction select" ,select-instructions ,interp-pseudo-x86-1)
    ; ("shrink" ,shrink ,interp-Lvec ,type-check-Lvec)
    ; ("uniquify" ,uniquify ,interp-Lvec ,type-check-Lvec)
    ; ("uncover get!" ,uncover-get! ,interp-Lvec ,type-check-Lvec-has-type)
    ; ("expose allocation" ,expose-allocation ,interp-Lvec-prime ,type-check-Lvec)
    ; ("remove complex opera*" ,remove-complex-opera* ,interp-Lvec-prime ,type-check-Lvec)
    ; ("explicate control" ,explicate-control ,interp-Cvec ,type-check-Cvec)
    ; ("instruction select" ,select-instructions ,interp-pseudo-x86-2)
    ("shrink" ,shrink ,interp-Lfun ,type-check-Lfun)
    ("uniquify" ,uniquify ,interp-Lfun ,type-check-Lfun)
    ("reveal functions" ,reveal-functions ,interp-Lfun-prime ,type-check-Lfun)
    ("limit functions" ,limit-functions ,interp-Lfun-prime ,type-check-Lfun)
    ("uncover get!" ,uncover-get! ,interp-Lfun-prime ,type-check-Lfun-has-type)
    ("expose allocation" ,expose-allocation ,interp-Lfun-prime ,type-check-Lfun)
    ("remove complex opera*" ,remove-complex-opera* ,interp-Lfun-prime ,type-check-Lfun)
    ("explicate control" ,explicate-control ,interp-Cfun ,type-check-Cfun)
    ("instruction select" ,select-instructions ,interp-pseudo-x86-3)
    ))

;; ORDER OF EXECUTION FOR LFUN
;; shrink -> uniquify -> reveal-functions -> limit-functions -> expose-allocation -> uncover-get! ->
;; remove-complex-opera* -> explicate-control -> select-instructions
