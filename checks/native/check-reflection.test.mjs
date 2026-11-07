import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkReflection } from './check-reflection.mjs';

function executable({ named = true, kind = 1 } = {}) {
  const b = Buffer.alloc(256);
  b.writeUInt32LE(0xfeedfacf, 0);
  b.writeUInt32LE(0x0100000c, 4);
  b.writeUInt32LE(1, 16);
  b.writeUInt32LE(0x19, 32);
  b.writeUInt32LE(152, 36);
  b.writeUInt32LE(1, 96);
  b.write('__swift5_fieldmd', 104);
  b.writeBigUInt64LE(28n, 144);
  b.writeUInt32LE(184, 152);
  b.writeUInt16LE(kind, 192);
  b.writeUInt16LE(12, 194);
  b.writeUInt32LE(1, 196);
  b.writeInt32LE(named ? 4 : 0, 208);
  b.write('_state\0', 212);
  return b;
}

test('accepts preserved class field names', () => {
  assert.equal(checkReflection(executable()), 1);
});
test('rejects stripped field names even when name strings exist elsewhere', () => {
  assert.throws(() => checkReflection(executable({ named: false })), /1\/1 Swift class fields have no names/);
});
test('rejects absent class metadata', () => {
  assert.throws(() => checkReflection(executable({ kind: 0 })), /No Swift class fields/);
});
test('rejects truncated metadata', () => {
  assert.throws(() => checkReflection(executable().subarray(0, 200)), /Truncated/);
});
