import test from 'node:test';
import assert from 'node:assert/strict';
import { mergeMessages, isFresh, filterTasks, buildTaskPayload, authorName, displayMessageBody, taskActivity, mergeActivity } from '../renderer/state.js';

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


test('activity needs a fresh connected active turn, not a claimed task', () => {
  const task = { state: 'working' };
  const detail = { task, runningEngineers: ['devin'] };
  const options = { connected: true, observedAt: 1000, now: 2000 };
  assert.equal(taskActivity(task, detail, options).animate, true);
  assert.match(taskActivity(task, detail, options).note, /does not confirm/);
  for (const change of [{ connected: false }, { observedAt: undefined }, { now: 16001 }, { now: 999 }]) {
    const result = taskActivity(task, detail, { ...options, ...change });
    assert.equal(result.animate, false);
    assert.equal(result.kind, 'unknown');
  }
  assert.equal(taskActivity(task, { task, runningEngineers: [] }, options).kind, 'waiting');
  assert.equal(taskActivity(task, { task }, options).kind, 'unknown');
});

test('fresh non-working states stop activity even if worker list lags', () => {
  for (const state of ['blocked', 'paused', 'awaiting_architecture_approval', 'verifying', 'completed', 'cancelled', 'failed']) {
    const result = taskActivity({ state: 'working' }, { task: { state }, runningEngineers: ['devin'] },
      { connected: true, observedAt: 1000, now: 2000 });
    assert.equal(result.animate, false, state);
    assert.equal(result.kind, 'idle', state);
  }
});

test('activity replay dedupes ordered task-scoped allowlisted events', () => {
  const event = seq => ({ seq, taskID: 'task_a', kind: 'tool', title: 'Read file' });
  assert.deepEqual(mergeActivity([event(2)], [event(1), event(2), { ...event(3), taskID: 'task_b' }, { ...event(4), kind: 'agent_thought' }], 'task_a').map(x => x.seq), [1, 2]);
});
