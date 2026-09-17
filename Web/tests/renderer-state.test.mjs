import test from 'node:test';
import assert from 'node:assert/strict';
import { mergeMessages, isFresh, filterTasks, buildTaskPayload, authorName, displayMessageBody } from '../renderer/state.js';

const message = (id, seq, body = id) => ({ id, seq, body, deliveryState: 'committed' });

test('message refresh dedupes, updates and retains earlier pages', () => {
  const result = mergeMessages([message('a', 1), message('c', 3, 'old')], [message('b', 2), message('c', 3, 'new'), { ...message('d', 4), deliveryState: 'streaming' }]);
  assert.deepEqual(result.map(item => item.seq), [1, 2, 3]);
  assert.equal(result[2].body, 'new');
});

test('selection generation rejects stale responses', () => {
  assert.equal(isFresh(1, 'a', 2, 'b'), false);
  assert.equal(isFresh(1, 'a', 2, 'a'), false);
  assert.equal(isFresh(2, 'b', 2, 'b'), true);
});

test('filters match persisted task fields and attention state', () => {
  const tasks = [{ title: 'Owner', brief: 'One', state: 'working', channel: 'engineering' }, { title: 'Peer', brief: 'Two', state: 'blocked', channel: 'research' }];
  assert.deepEqual(filterTasks(tasks, { view: 'needs' }), [tasks[1]]);
  assert.deepEqual(filterTasks(tasks, { view: 'space', space: 'engineering' }), [tasks[0]]);
  assert.deepEqual(filterTasks(tasks, { search: 'TWO' }), [tasks[1]]);
});

test('submission identity depends on invocation not brief', () => {
  const draft = { draft: 'Title\nFull objective', phase: 'execution', mode: 'owner_only', peers: ['kimi'], channel: 'engineering', uuid: 'one' };
  const first = buildTaskPayload(draft);
  assert.deepEqual(first, buildTaskPayload(draft));
  assert.notEqual(first.idempotency_key, buildTaskPayload({ ...draft, uuid: 'two' }).idempotency_key);
  assert.deepEqual(first.participants, []);
  assert.equal(first.title, 'Title');
  assert.equal(first.objective, 'Title\nFull objective');
  assert.deepEqual(buildTaskPayload({ ...draft, mode: 'requested_peers' }).participants, ['kimi']);
});

test('Codex provenance is explicit and malformed metadata harmless', () => {
  assert.equal(authorName('user', '{"via":"codex"}'), 'You (via Codex)');
  assert.equal(authorName('user', '{bad'), 'You');
  assert.equal(authorName('engineer:devin'), 'Devin Fusion');
});

test('displayMessageBody strips legacy generation marker only for system', () => {
  assert.equal(displayMessageBody({ author: 'system',
    body: 'Fusion claimed T (generation 12)' }), 'Fusion claimed T');
  assert.equal(displayMessageBody({ author: 'user',
    body: 'Fusion claimed T (generation 12)' }),
    'Fusion claimed T (generation 12)');
  assert.equal(displayMessageBody({ author: 'engineer:devin',
    body: 'Fusion claimed T (generation 12)' }),
    'Fusion claimed T (generation 12)');
});
