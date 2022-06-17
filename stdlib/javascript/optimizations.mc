include "javascript/ast.mc"
include "javascript/intrinsics.mc"

include "bool.mc"


-- Block Optimizations
lang JSOptimizeBlocks = JSExprAst

  sem flattenBlockHelper : JSExpr -> ([JSExpr], JSExpr)
  sem flattenBlockHelper =
  | JSEBlock { exprs = exprs, ret = ret } ->
    -- If the return value is a block, concat the expressions in that block with the
    -- expressions in the current block and set the return value to the return value
    -- of the current block
    -- For each expression in the current block, if it is a block, flatten it
    let flatExprs : [JSExpr] = filterNops (foldr (
      lam e. lam acc.
        let flatE = flattenBlockHelper e in
        match flatE with ([], e) then
          cons e acc
        else match flatE with (flatEExprs, flatERet) then
          join [acc, flatEExprs, [flatERet]]
        else never
    ) [] exprs) in

    -- Call flattenBlockHelper recursively on the return value
    let flatRet = flattenBlockHelper ret in
    match flatRet with ([], e) then
      -- Normal expressions are returned as is, thus concat them with the expressions
      -- in the current block
      (flatExprs, ret)
    else match flatRet with (retExprs, retRet) then
      (concat flatExprs retExprs, retRet)
    else never
  | expr -> ([], expr)

  sem flattenBlock : JSExpr -> JSExpr
  sem flattenBlock =
  | JSEBlock _ & block ->
    match flattenBlockHelper block with (exprs, ret) then
      JSEBlock { exprs = exprs, ret = ret }
    else never
  | expr -> expr

  sem immediatelyInvokeBlock : JSExpr -> JSExpr
  sem immediatelyInvokeBlock =
  | JSEBlock _ & block -> JSEIIFE { body = block }
  | expr -> expr

  sem filterNops : [JSExpr] -> [JSExpr]
  sem filterNops =
  | lst -> foldr (
    lam e. lam acc.
      match e with JSENop { } then acc else cons e acc
  ) [] lst

end

type JSTCOContext = {
  expr: JSExpr,
  foundTailCall: Bool
}

-- Tail Call Optimizations
lang JSOptimizeTailCalls = JSExprAst

  sem optimizeTailCall : Name -> Info -> JSExpr -> JSExpr
  sem optimizeTailCall (name: Name) (info: Info) =
  | JSEFun _ & fun ->
    -- Outer most lambda in the function to be optimized
    match runOnTailPositional name trampolineCapture fun with { expr = fun, foundTailCall = true } then
      -- Call wrapping function on the optimized function
      trampolineWrap fun
    else
      -- Otherwise, return the function as is
      fun
  | _ -> errorSingle [info] "Non-lambda expressions cannot be optimized for tail calls when compiling to JavaScript"


  sem runOnTailPositional : Name -> (JSExpr -> JSExpr) -> JSExpr -> JSTCOContext
  sem runOnTailPositional (name: Name) (action: (JSExpr -> JSExpr)) =
  | JSEApp { fun = fun } & t ->
    -- If the function is a tail call, run the action on the function
    -- and replace the function with the result
    match fun with JSEVar { id = name } then {
      expr = action t,
      foundTailCall = true
    } else {
      expr = t,
      foundTailCall = false
    }
  | JSEFun      t -> runWithJSTCOCtx name action t.body (lam e. JSEFun { t with body = e })
  | JSEIIFE     t -> runWithJSTCOCtx name action t.body (lam e. JSEIIFE { t with body = e })
  | JSEBlock    t -> runWithJSTCOCtx name action t.ret (lam e. JSEBlock { t with ret = e })
  | JSETernary  t -> runWithJSTCOCtx2 name action t.thn t.els (lam e1. lam e2. JSETernary { t with thn = e1, els = e2 })
  | t -> { expr = t, foundTailCall = false } -- No terms where tail calls can be located


  sem runWithJSTCOCtx : Name -> (JSExpr -> JSExpr) -> JSExpr -> (JSExpr -> JSExpr) -> JSTCOContext
  sem runWithJSTCOCtx name action expr =
    | constr ->
      let res = runOnTailPositional name action expr in {
        expr = constr res.expr,
        foundTailCall = res.foundTailCall
      }

  sem runWithJSTCOCtx2 : Name -> (JSExpr -> JSExpr) -> JSExpr -> JSExpr -> (JSExpr -> JSExpr -> JSExpr) -> JSTCOContext
  sem runWithJSTCOCtx2 name action expr1 expr2 =
    | constr ->
      let res1 = runOnTailPositional name action expr1 in
      let res2 = runOnTailPositional name action expr2 in {
        expr = constr res1.expr res2.expr,
        foundTailCall = or res1.foundTailCall res2.foundTailCall
      }

  -- Strategies for optimizing tail calls

  -- Wrap all calls in a trampoline capture that is immediately returned
  sem trampolineCapture : JSExpr -> JSExpr
  sem trampolineCapture =
  | JSEApp { fun = fun, args = args } ->
    -- Transform function calls to a trampoline capture intrinsic
    intrinsicFromString intrGenNS "trampolineCapture" [fun, JSEArray{ exprs = args }]
  | _ -> error "trampolineCapture called on non-function application expression"

  sem trampolineWrap : JSExpr -> JSExpr
  sem trampolineWrap =
  | JSEFun _ & fun ->
    -- Wrap the function body in a trampoline capture
    fun
  | _ -> error "trampolineWrap called on non-function expression"

end



-- Pattern Matching Optimizations
lang JSOptimizePatterns = JSExprAst

  sem optimizePattern : JSExpr -> JSExpr
  sem optimizePattern =
  | JSEBinOp {
      op = JSOEq {},
      lhs = JSEBool { b = true },
      rhs = e
    } -> e
  | e -> e

end
