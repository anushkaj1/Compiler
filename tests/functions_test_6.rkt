(define (func [int1 : Integer] [int2 : Integer] [res1 : Integer] [res2 : Integer]) : Integer
    (let ([x int1])
        (let ([y int2])
            (if (if (< x 1) (eq? x 0) (eq? x 2)) res1
                res2))))
(func 15 5 (+ 5 2) (+ 5 10))