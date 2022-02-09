include "c/ast.mc"
include "c/pprint.mc"
include "futhark/alias-analysis.mc"
include "futhark/deadcode.mc"
include "futhark/for-each-record-pat.mc"
include "futhark/generate.mc"
include "futhark/pprint.mc"
include "futhark/record-lift.mc"
include "futhark/size-parameterize.mc"
include "futhark/wrapper.mc"
include "mexpr/boot-parser.mc"
include "mexpr/cse.mc"
include "mexpr/lamlift.mc"
include "mexpr/symbolize.mc"
include "mexpr/type-annot.mc"
include "mexpr/utesttrans.mc"
include "ocaml/generate.mc"
include "ocaml/pprint.mc"
include "options.mc"
include "sys.mc"
include "pmexpr/ast.mc"
include "pmexpr/c-externals.mc"
include "pmexpr/demote.mc"
include "pmexpr/extract.mc"
include "pmexpr/nested-accelerate.mc"
include "pmexpr/parallel-rewrite.mc"
include "pmexpr/recursion-elimination.mc"
include "pmexpr/replace-accelerate.mc"
include "pmexpr/rules.mc"
include "pmexpr/tailrecursion.mc"
include "pmexpr/utest-size-constraint.mc"
include "pmexpr/well-formed.mc"
include "parse.mc"

lang PMExprCompile =
  BootParser +
  MExprSym + MExprTypeAnnot + MExprUtestTrans + PMExprAst +
  MExprANF + PMExprDemote + PMExprRewrite + PMExprTailRecursion +
  PMExprParallelPattern + PMExprCExternals + MExprLambdaLift + MExprCSE +
  PMExprRecursionElimination + PMExprExtractAccelerate +
  PMExprReplaceAccelerate + PMExprNestedAccelerate +
  PMExprUtestSizeConstraint + PMExprWellFormed + FutharkGenerate +
  FutharkDeadcodeElimination + FutharkSizeParameterize + FutharkCWrapper +
  FutharkRecordParamLift + FutharkForEachRecordPattern + FutharkAliasAnalysis +
  OCamlGenerate + OCamlTypeDeclGenerate
end

let parallelKeywords = [
  "accelerate",
  "map2",
  "parallelFlatten",
  "parallelReduce"
]

let keywordsSymEnv =
  {symEnvEmpty with varEnv =
    mapFromSeq
      cmpString
      (map (lam s. (s, nameSym s)) parallelKeywords)}

let parallelPatterns = [
  getMapPattern (),
  getMap2Pattern (),
  getReducePattern ()
]

let pprintOCamlTops : [Top] -> String = lam tops.
  use OCamlPrettyPrint in
  pprintOcamlTops tops

let pprintFutharkAst : FutProg -> String = lam ast.
  use FutharkPrettyPrint in
  printFutProg ast

let pprintCAst : CPProg -> String = lam ast.
  use CPrettyPrint in
  use CProgPrettyPrint in
  printCProg [] ast

let patternTransformation : Expr -> Expr = lam ast.
  use PMExprCompile in
  let ast = replaceUtestsWithSizeConstraint ast in
  let ast = rewriteTerm ast in
  let ast = tailRecursive ast in
  let ast = cseGlobal ast in
  let ast = normalizeTerm ast in
  let ast = parallelPatternRewrite parallelPatterns ast in
  eliminateRecursion ast

let validatePMExprAst : Set Name -> Expr -> () = lam accelerateIds. lam ast.
  use PMExprCompile in
  reportNestedAccelerate accelerateIds ast ;
  pmexprWellFormed ast

let futharkTranslation : Expr -> FutProg = lam entryPoints. lam ast.
  use PMExprCompile in
  let ast = generateProgram entryPoints ast in
  let ast = liftRecordParameters ast in
  let ast = useRecordPatternInForEach ast in
  let ast = aliasAnalysis ast in
  let ast = deadcodeElimination ast in
  parameterizeSizes ast

let filename = lam path.
  match strLastIndex '/' path with Some idx then
    subsequence path (addi idx 1) (length path)
  else path

let filenameWithoutExtension = lam filename.
  match strLastIndex '.' filename with Some idx then
    subsequence filename 0 idx
  else filename

let compileAccelerated : Options -> String -> String -> String -> String -> Unit =
  lam options. lam sourcePath. lam ocamlProg. lam cProg. lam futharkProg.
  let linkedFiles =
    if options.cpuOnly then ""
    else "(link_flags -cclib -lcuda -cclib -lcudart -cclib -lnvrtc)"
  in
  let dunefile = join ["
(env (dev (flags (:standard -w -a)) (ocamlc_flags (-without-runtime))))
(executable (name program) (libraries boot)",
  linkedFiles,
  "(foreign_stubs (language c) (names gpu wrap)))"] in

  let envVariables =
    if options.cpuOnly then ""
    else
"export LIBRARY_PATH=/usr/local/cuda/lib64
export LD_LIBRARY_PATH=/usr/local/cuda/lib64/
export CPATH=/usr/local/cuda/include" in
  let futharkCompileCommand =
    if options.cpuOnly then
      "futhark multicore --library $^"
    else
      "futhark cuda --library $^" in
  let makefile = join [envVariables,
"
program: program.ml wrap.c gpu.c
	dune build $@.exe

gpu.c gpu.h: gpu.fut
	", futharkCompileCommand] in

  let td = sysTempDirMake () in
  let dir = sysTempDirName td in
  let tempfile = lam f. sysJoinPath dir f in

  writeFile (tempfile "program.ml") ocamlProg;
  writeFile (tempfile "program.mli") "";
  writeFile (tempfile "wrap.c") cProg;
  writeFile (tempfile "gpu.fut") futharkProg;
  writeFile (tempfile "dune") dunefile;
  writeFile (tempfile "Makefile") makefile;

  -- TODO(larshum, 2021-09-17): Remove dependency on Makefile. For now, we use
  -- it because dune cannot set environment variables.
  let command = ["make"] in
  let r = sysRunCommand command "" dir in
  (if neqi r.returncode 0 then
    print (join ["Make failed:\n\n", r.stderr]);
    sysTempDirDelete td;
    exit 1
  else ());
  let binPath = tempfile "_build/default/program.exe" in
  let destinationFile = filenameWithoutExtension (filename sourcePath) in
  sysMoveFile binPath destinationFile;
  sysChmodWriteAccessFile destinationFile;
  sysTempDirDelete td ();
  ()

let compileAccelerated : Options -> String -> Unit = lam options. lam file.
  use PMExprCompile in
  let ast = parseParseMCoreFile {
    keepUtests = true,
    pruneExternalUtests = false,
    pruneExternalUtestsWarning = false,
    findExternalsExclude = false,
    keywords = parallelKeywords
  } file in
  let ast = makeKeywords [] ast in

  let ast = symbolizeExpr keywordsSymEnv ast in
  let ast = typeAnnot ast in
  let ast = removeTypeAscription ast in

  -- Translate accelerate terms into functions with one dummy parameter, so
  -- that we can accelerate terms without free variables and so that it is
  -- lambda lifted.
  match addIdentifierToAccelerateTerms ast with (accelerated, ast) in

  -- Perform lambda lifting and return the free variable solutions
  match liftLambdasWithSolutions ast with (solutions, ast) in

  -- Extract the accelerate AST
  let accelerateIds : Set Name = mapMap (lam. ()) accelerated in
  let accelerateAst = extractAccelerateTerms accelerateIds ast in

  -- Eliminate the dummy parameter in functions of accelerate terms with at
  -- least one free variable parameter.
  match eliminateDummyParameter solutions accelerated accelerateAst
  with (accelerated, accelerateAst) in

  -- BEGIN Futhark generation --

  -- Detect patterns in the accelerate AST to eliminate recursion. The
  -- result is a PMExpr AST.
  let pmexprAst = patternTransformation accelerateAst in

  -- Perform validation of the produced PMExpr AST to ensure it is valid
  -- in terms of the well-formed rules. If it is found to violate these
  -- constraints, an error is reported.
  validatePMExprAst accelerateIds pmexprAst ;

  -- Translate the PMExpr AST into a Futhark AST, and then pretty-print
  -- the result.
  let futharkAst = futharkTranslation accelerateIds pmexprAst in
  let futharkProg = pprintFutharkAst futharkAst in

  -- END Futhark generation --

  -- BEGIN C wrapper generation --

  let cAst = generateWrapperCode accelerated in
  let cProg = pprintCAst cAst in

  -- END C wrapper generation --

  -- BEGIN OCaml generation --

  -- Eliminate all utests in the MExpr AST
  let ast = utestStrip ast in

  -- Construct a sequential version of the AST where parallel constructs have
  -- been demoted to sequential equivalents
  let ast = demoteParallel ast in

  match typeLift ast with (env, ast) in
  match generateTypeDecls env with (env, typeTops) in

  -- Replace auxilliary accelerate terms in the AST by eliminating
  -- the let-expressions (only used in the accelerate AST) and adding
  -- data conversion of parameters and result.
  let ast = replaceAccelerate accelerated ast in

  -- Generate the OCaml AST
  let exprTops = generateTops env ast in

  -- Add an external declaration of a C function in the OCaml AST,
  -- for each accelerate term.
  let externalTops = getExternalCDeclarations accelerated in

  let ocamlTops = join [externalTops, typeTops, exprTops] in
  let ocamlProg = pprintOCamlTops ocamlTops in
  compileAccelerated options file ocamlProg cProg futharkProg

  -- END OCaml generation --

let compileAccelerate = lam files. lam options : Options. lam args.
  if options.runTests then
    error "Flags --test and --accelerate may not be used at the same time"
  else iter (compileAccelerated options) files