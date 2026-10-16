// Privacy check for this repository. Run: bun scripts/privacy-check.ts <dir>
/**
 * Privacy and secret scan of a folder, before anything in it reaches a public repo.
 *
 * Every regular file is read: text through the generic rules (and a denylist when one is given),
 * PNG and JPEG files for embedded text metadata, any other binary reported once for a person to
 * look at. gitleaks then scans the same folder. A finding prints as `file:line rule`, never the
 * text that matched, so the output can be shown and kept without repeating what it found.
 *
 * A binary a person has reviewed is listed in `.privacy-reviewed` (`sha256  path` per line) and
 * passes while its content still matches the hash; a changed binary is reported again.
 *
 * Usage: bun <this file> <dir> [--denylist <file>] [--reviewed <file>]   (or PRIVACY_DENYLIST=<file>)
 * Exit: 0 nothing found, 1 findings, 2 the scan could not run.
 */
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';

export type Rule = {
  readonly label: string;
  readonly pattern: RegExp;
  /** A match this returns true for is no finding. */
  readonly allow?: (match: string) => boolean;
};

export type Finding = { readonly file: string; readonly line: number; readonly rule: string };

/** Reviewed binaries: path → sha256 of the content a person looked at. */
export type Reviewed = ReadonlyMap<string, string>;

const REVIEWED_FILE = '.privacy-reviewed';
const REVIEWED_LINE = /^([0-9a-f]{64})\s+(.+)$/;

/** `sha256  path` per line; `#` comments and blank lines skipped. */
export function parseReviewed(text: string): Reviewed {
  return new Map(text.split('\n').flatMap((raw, index) => {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) return [];
    const match = REVIEWED_LINE.exec(line);
    if (match === null) throw new Error(`reviewed list line ${index + 1}: expected "sha256  path"`);
    return [[match[2]!, match[1]!] as const];
  }));
}

const sha256 = (bytes: Uint8Array): string => new Bun.CryptoHasher('sha256').update(bytes).digest('hex');

const EXIT_CLEAN = 0;
const EXIT_FOUND = 1;
const EXIT_FAILED = 2;
const BINARY_SNIFF_BYTES = 8000;
const SKIPPED_DIRS = new Set(['.git', 'node_modules']);
const IMAGE_FILE = /\.(png|jpe?g)$/i;
const PNG_TEXT_CHUNKS = new Set(['tEXt', 'iTXt', 'zTXt', 'eXIf']);
const JPEG_APP1 = 0xe1;

export const ALLOWED_EMAILS: readonly string[] = ['marcostomatti.cv@gmail.com'];
const ALLOWED_EMAIL_DOMAINS = /@(example\.(com|org|net)|users\.noreply\.github\.com)$/i;
const NOREPLY_ADDRESS = /^no-?reply@/i;

const allowedEmail = (address: string): boolean =>
  ALLOWED_EMAILS.includes(address.toLowerCase()) || ALLOWED_EMAIL_DOMAINS.test(address) || NOREPLY_ADDRESS.test(address);

const OCTET = '\\d{1,3}';
const PRIVATE_PREFIX = `(?:10\\.${OCTET}|172\\.(?:1[6-9]|2\\d|3[01])|192\\.168|100\\.(?:6[4-9]|[7-9]\\d|1[01]\\d|12[0-7]))`;

export const GENERIC_RULES: readonly Rule[] = [
  { label: 'private-ip', pattern: new RegExp(`(?<![\\d.])${PRIVATE_PREFIX}\\.${OCTET}\\.${OCTET}(?!\\d)`, 'g') },
  { label: 'home-path', pattern: /\/(?:Users|home)\/(?!(?:tester|user|runner)(?![\w.-]))[A-Za-z0-9._-]+/g },
  { label: 'email', pattern: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, allow: allowedEmail },
  { label: 'telegram-token', pattern: /(?<![\dA-Za-z])\d{8,10}:[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])/g },
  { label: 'telegram-chat', pattern: /(?<!\d)-100\d{9,}/g },
];

/** One rule per `label<TAB>regex` line; `#` comments and blank lines skipped; matched case-insensitively. */
export function parseDenylist(text: string): readonly Rule[] {
  return text.split('\n').flatMap((raw, index) => {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) return [];
    const tab = raw.indexOf('\t');
    if (tab < 0) throw new Error(`denylist line ${index + 1}: no tab between label and regex`);
    const label = raw.slice(0, tab).trim();
    try {
      return [{ label, pattern: new RegExp(raw.slice(tab + 1).trim(), 'gi') }];
    } catch (error) {
      throw new Error(`denylist line ${index + 1}: ${(error as Error).message}`);
    }
  });
}

function lineMatches(line: string, rule: Rule): boolean {
  const matches = line.match(new RegExp(rule.pattern.source, rule.pattern.flags.includes('g') ? rule.pattern.flags : `${rule.pattern.flags}g`));
  return (matches ?? []).some((match) => !(rule.allow?.(match) ?? false));
}

/** One finding per line and rule that matches it. */
export function scanText(file: string, text: string, rules: readonly Rule[]): readonly Finding[] {
  return text.split('\n').flatMap((line, index) =>
    rules.filter((rule) => lineMatches(line, rule)).map((rule) => ({ file, line: index + 1, rule: rule.label })),
  );
}

function pngHasText(bytes: Uint8Array): boolean {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let at = 8; at + 8 <= bytes.length; at += 12 + view.getUint32(at)) {
    const type = new TextDecoder().decode(bytes.subarray(at + 4, at + 8));
    if (PNG_TEXT_CHUNKS.has(type)) return true;
  }
  return false;
}

function jpegHasApp1(bytes: Uint8Array): boolean {
  for (let at = 2; at + 4 <= bytes.length && bytes[at] === 0xff; ) {
    const marker = bytes[at + 1]!;
    if (marker === JPEG_APP1) return true;
    if (marker === 0xd9 || marker === 0xda) return false;
    at += 2 + ((bytes[at + 2]! << 8) | bytes[at + 3]!);
  }
  return false;
}

const isPng = (bytes: Uint8Array): boolean => bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
const isJpeg = (bytes: Uint8Array): boolean => bytes[0] === 0xff && bytes[1] === 0xd8;
const isImage = (bytes: Uint8Array): boolean => isPng(bytes) || isJpeg(bytes);

/** A PNG text chunk or a JPEG APP1 (Exif, XMP) segment is one finding for the file. */
export function imageMetadata(file: string, bytes: Uint8Array): readonly Finding[] {
  const found = (isPng(bytes) && pngHasText(bytes)) || (isJpeg(bytes) && jpegHasApp1(bytes));
  return found ? [{ file, line: 0, rule: 'image-metadata' }] : [];
}

/** Every file and symlink under `dir`; `.git` and `node_modules` are skipped at the top level only. */
function entriesUnder(dir: string, top: boolean): readonly { readonly path: string; readonly link: boolean }[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return top && SKIPPED_DIRS.has(entry.name) ? [] : entriesUnder(path, false);
    if (entry.isSymbolicLink()) return [{ path, link: true }];
    return entry.isFile() ? [{ path, link: false }] : [];
  });
}

/** Every regular file under `dir`, paths in findings relative to it. */
export async function scanDir(dir: string, rules: readonly Rule[], reviewed: Reviewed = new Map()): Promise<readonly Finding[]> {
  return entriesUnder(dir, true).flatMap(({ path, link }) => {
    const file = relative(dir, path);
    if (link) return [{ file, line: 0, rule: 'symlink-unreviewed' }];
    const bytes = new Uint8Array(readFileSync(path));
    if (IMAGE_FILE.test(file) && isImage(bytes)) return imageMetadata(file, bytes);
    if (bytes.subarray(0, BINARY_SNIFF_BYTES).includes(0)) {
      return reviewed.get(file) === sha256(bytes) ? [] : [{ file, line: 0, rule: 'binary-unreviewed' }];
    }
    return scanText(file, new TextDecoder().decode(bytes), rules);
  });
}

type GitleaksHit = { readonly File: string; readonly StartLine: number; readonly RuleID: string };

function gitleaks(dir: string): readonly Finding[] {
  const reportDir = mkdtempSync(join(tmpdir(), 'gitleaks-'));
  const report = join(reportDir, 'report.json');
  try {
    return gitleaksInto(dir, report);
  } finally {
    rmSync(reportDir, { recursive: true, force: true });
  }
}

function gitleaksInto(dir: string, report: string): readonly Finding[] {
  const run = Bun.spawnSync(
    ['gitleaks', 'dir', '--redact', '--no-banner', '--report-format', 'json', '--report-path', report, '--exit-code', '0', dir],
    { stdout: 'ignore', stderr: 'pipe' },
  );
  if (run.exitCode !== 0) throw new Error(`gitleaks failed: ${run.stderr.toString().trim()}`);
  const hits = JSON.parse(readFileSync(report, 'utf8')) as readonly GitleaksHit[];
  return hits.map((hit) => ({ file: relative(dir, hit.File), line: hit.StartLine, rule: `gitleaks:${hit.RuleID}` }));
}

export function denylistPath(args: readonly string[]): string | undefined {
  const flag = args.indexOf('--denylist');
  if (flag >= 0 && (args[flag + 1] === undefined || args[flag + 1] === '')) throw new Error('--denylist needs a file');
  const path = flag >= 0 ? args[flag + 1] : process.env.PRIVACY_DENYLIST;
  if (path === undefined || path === '') return undefined;
  if (!existsSync(path)) throw new Error('the denylist file named does not exist');
  return path;
}

function reviewedList(dir: string, args: readonly string[]): Reviewed {
  const flag = args.indexOf('--reviewed');
  if (flag >= 0 && (args[flag + 1] === undefined || args[flag + 1] === '')) throw new Error('--reviewed needs a file');
  const path = flag >= 0 ? args[flag + 1]! : join(dir, REVIEWED_FILE);
  return existsSync(path) ? parseReviewed(readFileSync(path, 'utf8')) : new Map();
}

async function main(args: readonly string[]): Promise<number> {
  const dir = args[0];
  if (dir === undefined || !existsSync(dir) || !statSync(dir).isDirectory()) {
    console.error(`usage: bun ${relative(process.cwd(), process.argv[1] ?? 'this file')} <dir> [--denylist <file>] [--reviewed <file>]`);
    return EXIT_FAILED;
  }
  try {
    const listed = denylistPath(args);
    const rules = [...GENERIC_RULES, ...(listed ? parseDenylist(readFileSync(listed, 'utf8')) : [])];
    const findings = [...(await scanDir(dir, rules, reviewedList(dir, args))), ...gitleaks(dir)];
    const lines = findings.map((f) => `${f.file}:${f.line} ${f.rule}`).sort();
    lines.forEach((line) => console.log(line));
    console.log(`${lines.length} finding(s)${listed ? '' : ' (no denylist)'}`);
    return lines.length === 0 ? EXIT_CLEAN : EXIT_FOUND;
  } catch (error) {
    console.error(`scan could not run: ${(error as Error).message}`);
    return EXIT_FAILED;
  }
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)));
