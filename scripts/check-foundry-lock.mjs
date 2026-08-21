// foundry.lock is only a record unless something reads it: every library it
// names must be checked out at the rev it names. Part of `npm run check`, so
// it runs locally and in CI alike.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const root = new URL("../contracts/", import.meta.url).pathname;
const lock = JSON.parse(readFileSync(`${root}foundry.lock`, "utf8"));
const status = execFileSync("git", ["submodule", "status"], { cwd: root, encoding: "utf8" });

const checkedOut = Object.fromEntries(
  status
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => l.trim().split(/\s+/))
    .map(([rev, path]) => [path, rev.replace(/^[+\-U]/, "")]),
);

const bad = Object.entries(lock).flatMap(([path, entry]) => {
  const want = entry.rev ?? entry.tag?.rev ?? entry.branch?.rev;
  const have = checkedOut[path];
  return have === want ? [] : [`${path}: foundry.lock ${want} vs checkout ${have}`];
});

if (bad.length) {
  console.error(bad.join("\n"));
  process.exit(1);
}
console.log(`foundry.lock matches ${Object.keys(lock).length} libraries`);
