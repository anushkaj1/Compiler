(define (limit-tester [a1 : Integer] [a2 : Integer] [a3 : Integer] [a4 : Integer] [a5 : Integer] [a6 : Integer] [a7 : Integer])
    : Integer
    (+ a1 (+ a2 (+ a3 (+ a4 (+ a5 (+ a6 a7)))))))
(limit-tester 1 2 3 4 5 6 7)