const { execSync } = require('child_process');

const ROOT = process.cwd().substring(0, process.cwd().indexOf("miking")) + "miking/";
const BUILD = ROOT + "build/";
const BENCH = ROOT + "test/js/benchmarks/";

function menu() {
  console.log(`Usage: run <benchmark-name-without-postfix-name> <iteration> (clean?)

Example:
  run factorial 100      - Run the fibonacci benchmark 100 times
  run factorial 100 true - Run the fibonacci benchmark 100 times and clean up the generated JavaScript
  `);
  process.exit(1);
}

function compile(benchmark) {
  console.log(`Compiling benchmark '${benchmark}'...`);
  execSync(`cd ${ROOT}; cd stdlib; export MCORE_STDLIB=\`pwd\`; cd ..; ${BUILD}boot eval ${ROOT}src/main/mi.mc -- compile --to-js --js-target node ${BENCH}${benchmark}.mc`);
}

function cleanup(benchmark) {
  execSync(`rm ${BENCH}${benchmark}.js`);
}

function run(title, cmd) {
  process.stdout.write(`- ${title.padEnd(20)}: `);
  const start = Date.now();
  try { execSync(cmd + " 2>&1") }
  catch(e) {
    console.log(e.message);
    return undefined;
  }
  const end = Date.now();
  const time = end - start;
  process.stdout.write(`${time}ms\n`);
  return time;
}

function fixed(n, digits) {
  return Math.floor(n * Math.pow(10, digits)) / Math.pow(10, digits);
}

function compare(firstName, first, secondName, second) {
  if (!first || !second) {
    console.log(`${firstName} and ${secondName} are not comparable.`);
    return;
  }
  const ratio = second / first;
  const changeInPrecent = fixed(100 * (ratio - 1), 1); // fixed(100 * (1 - first / second), 2)
  const fast = ratio > 1;
  console.log(
    `> ${firstName} is about`,
    fixed(ratio, 3),
    "times",
    fast ? "faster" : "slower",
    `than ${secondName}${fast ? "!" : "..."}`,
    // Precentage difference (improvement)
    ` \t(a ${changeInPrecent}% ${fast ? "improvement" : "degradation"})`
    );
  // console.log(`${title}: ${ratio}x`, ratio > 1 ? "faster" : "slower");
}

function main(args) {
  if (args.length < 2) menu();
  const benchmark = args[0];
  const iterations = parseInt(args[1]);
  const clean = args.length > 2 && args[2] === 'true';
  compile(benchmark);
  console.log(`Running benchmark '${benchmark}' for ${iterations} iterations...`);
  const mi   = run("Miking interpreter", `${BUILD}mi eval ${BENCH}${benchmark}.mc -- ${iterations}`);
  const boot = run("Boot interpreter", `${BUILD}boot eval ${BENCH}${benchmark}.mc -- ${iterations}`);
  const nodeMan = run("Node (manual)", `node ${BENCH}${benchmark}.man.js ${iterations}`);
  const nodeCmp = run("Node (compiled)", `node ${BENCH}${benchmark}.js ${iterations}`);
  const bunMan = run("Bun  (manual)", `bun run ${BENCH}${benchmark}.man.js ${iterations}`);
  const bunCmp = run("Bun  (compiled)", `bun run ${BENCH}${benchmark}.js ${iterations}`);
  if (clean) cleanup(benchmark);

  // Compare results
  // const bootToNode = node / boot;
  // const miToNode   = node / mi;
  // const ManToCmp   = nodeMan / nodeCmp;
  // console.log(`Boot vs Node: ${bootToNode}x`, bootToNode > 1 ? "faster" : "slower");
  // console.log(`Mi vs Node: ${miToNode}x`, miToNode > 1 ? "faster" : "slower");
  // console.log(`Node manual vs compiled: ${ManToCmp}x`, ManToCmp > 1 ? "faster" : "slower");
  // compare("Node manual vs compiled",  nodeMan, nodeCmp);
  console.log("Benchmark finished!");
  compare("(Node) Compiled JS code", nodeCmp, "interpreted Miking code", mi);
  compare("(Node) Compiled JS code", nodeCmp, "interpreted Boot code", boot);
  compare("(Node) Compiled JS code", nodeCmp, "the manual JS implementation (Node)", nodeMan);
  compare("(Bun)  Compiled JS code", bunCmp, "interpreted Miking code", mi);
  compare("(Bun)  Compiled JS code", bunCmp, "interpreted Boot code", boot);
  compare("(Bun)  Compiled JS code", bunCmp, "the manual JS implementation (Bun)", bunMan);
}

if (require.main === module) {
  main(process.argv.slice(2));
}