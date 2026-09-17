import { createHTTPClient } from './client.js';
import { mergeMessages, filterTasks, taskNeedsInput, buildTaskPayload, authorName, authorColor, parseProposal, displayMessageBody, taskActivity, mergeActivity } from './state.js';

const api = window.workshop ?? createHTTPClient();
const root = document.getElementById('root');
const tabs = ['Conversation', 'Ownership', 'Proposals', 'Decisions', 'Files'];
const members = [
  { id: 'devin', name: 'Devin Fusion', initial: 'F', color: 'fusion', role: 'Delivery owner' },
  { id: 'kimi', name: 'Kimi K3', initial: 'K', color: 'kimi', role: 'Peer engineer' },
  { id: 'deepseek', name: 'DeepSeek', initial: 'D', color: 'deepseek', role: 'Peer engineer' },
  { id: 'astra', name: 'Astra', initial: 'A', color: 'astra', role: 'Computer operator' },
];
const state = {
  tasks: [], engineers: [], capacity: null, selected: null, tab: 'Conversation',
  space: 'engineering', view: 'all', search: '', threadOpen: true, connected: false,
  error: '', loading: true, draft: '', phase: 'execution', mode: 'owner_only', peers: [],
  optionsOpen: false, pendingCreate: null, submitting: false, details: new Map(),
  messages: new Map(), proposals: new Map(), decisions: new Map(), files: new Map(),
  replyDrafts: new Map(), replyPending: new Set(), replyUncertain: new Set(),
  hasEarlier: new Map(), earlierLoading: false, activityObserved: new Map(), activity: new Map(), activityError: new Set(), activityMore: new Set(), activityOpen: new Set(),
};
let selectionGeneration = 0;
let refreshGeneration = 0;
let refreshTimer;
let profileObservedAt = 0;
let dialogOpener;
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const symbol = name => `<img class="symbol" src="/assets/${name}.png" alt="">`;
const button = (action, label, content, className = '', disabled = false) => `<button type="button" class="${className}" data-action="${action}" aria-label="${esc(label)}" ${disabled ? 'disabled' : ''}>${content}</button>`;
const avatar = (initial = 'Y', color = 'user', small = false) => `<span class="avatar ${color} ${small ? 'small' : ''}">${esc(initial)}</span>`;
const member = id => members.find(item => item.id === id);
const dateText = value => {
  if (!value) return '';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Unknown' : date.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
};
const label = value => String(value ?? 'Unknown').replaceAll('_', ' ');
const testAdapters = () => state.engineers.some(item => item.effectiveModel === 'fake-model');
const probe = id => state.engineers.find(item => item.engineer === id);
const selectedTask = () => state.tasks.find(task => task.id === state.selected);
const visibleTasks = () => filterTasks(state.tasks, state);
const disabledNav = (icon, name) => `<button type="button" disabled title="Not available in this build">${symbol(icon)}<span>${name}</span></button>`;

function activityMarkup(task, detail) {
  const activity = taskActivity(task, detail, { connected: state.connected,
    observedAt: state.activityObserved.get(task.id) });
  const names = (activity.engineers ?? []).map(id => member(id)?.name ?? id).join(', ');
  return `<span class="activity-label">${esc(activity.text)}</span>${activity.animate ? '<span class="activity-dots" aria-hidden="true"><i></i><i></i><i></i></span>' : ''}${names ? `<span class="activity-worker">${esc(names)} · active turn</span>` : ''}${activity.note ? `<span class="activity-note">${esc(activity.note)}</span>` : ''}`;
}

function activityHistory(task) {
  const items = state.activity.get(task.id) ?? [];
  const ended = new Set(items.filter(item => item.kind === 'lifecycle' && ['completed', 'cancelled', 'uncertain', 'failed'].includes(item.status)).map(item => item.turnID));
  return `<details id="activity-history" ${state.activityOpen.has(task.id) ? 'open' : ''}><summary>Work activity · ${items.length} events</summary><p class="activity-disclosure">Reported tool events and turn lifecycle. This is not a thinking transcript.</p>${state.activityError.has(task.id) ? '<p role="status">Activity history unavailable · retrying</p>' : ''}<ol>${items.map(item => `<li><time>${esc(dateText(item.createdAt))}</time><span>${esc(member(item.engineer)?.name ?? item.engineer)} · ${esc(item.kind === 'lifecycle' ? 'Turn lifecycle' : 'Reported ' + item.kind)}</span><b>${esc(item.title)}</b><span>${esc(label(item.status))}${item.kind === 'tool' && ended.has(item.turnID) && !['completed', 'failed', 'denied', 'cancelled'].includes(item.status) ? ' · turn ended; no final tool result in this event' : ''}</span>${item.callID ? `<small>Tool reference: ${esc(item.callID.slice(0, 12))}</small>` : ''}</li>`).join('')}</ol>${!items.length && !state.activityError.has(task.id) ? '<p>No recorded activity. Earlier turns may predate activity recording.</p>' : ''}${state.activityMore.has(task.id) ? button('more-activity', 'Load more activity', 'Load more activity', 'text-link') : ''}</details>`;
}

function updateActivityHistory() {
  const element = document.getElementById('activity-history-container');
  const task = selectedTask();
  if (!element || !task) return;
  const markup = activityHistory(task);
  if (element._activityMarkup !== markup) {
    element._activityMarkup = markup;
    const top = element.querySelector('ol')?.scrollTop ?? 0;
    element.innerHTML = markup;
    if (element.querySelector('ol')) element.querySelector('ol').scrollTop = top;
    element.querySelector('details')?.addEventListener('toggle', event => {
      if (event.target.open) state.activityOpen.add(task.id); else state.activityOpen.delete(task.id);
    });
  }
}

async function loadActivity(id) {
  const existing = state.activity.get(id) ?? [];
  try {
    const page = await api.getActivity(id, existing.at(-1)?.seq ?? 0);
    state.activity.set(id, mergeActivity(state.activity.get(id) ?? [], page, id));
    state.activityError.delete(id);
    if (page.length === 200) state.activityMore.add(id); else state.activityMore.delete(id);
  } catch { state.activityError.add(id); }
  updateActivityHistory();
}

function updateActivity() {
  const element = document.getElementById('task-activity');
  const task = selectedTask();
  if (!element || !task) return;
  const markup = activityMarkup(task, state.details.get(task.id));
  // Preserve animation and avoid repeated screen-reader announcements when unchanged.
  if (element.innerHTML !== markup) element.innerHTML = markup;
}

let activityPolling = false;
async function pollActivity() {
  updateActivity();
  const id = state.selected;
  if (!id || !state.connected || activityPolling) return;
  activityPolling = true;
  const observedAt = Date.now();
  try {
    const detail = await api.getTask(id);
    if (id !== state.selected || !state.connected || (state.activityObserved.get(id) ?? 0) > observedAt) return;
    state.details.set(id, detail);
    state.activityObserved.set(id, observedAt);
  } catch {
    state.activityObserved.delete(id);
  } finally {
    activityPolling = false;
    updateActivity();
    if (id === state.selected) void loadActivity(id);
  }
}

function taskOptions() {
  return `<details id="task-options" ${state.optionsOpen ? 'open' : ''}>
    <summary>Task options</summary>
    <div class="task-options"><label>Phase<select id="phase" ${state.pendingCreate ? 'disabled' : ''}>
      <option value="execution" ${state.phase === 'execution' ? 'selected' : ''}>Execution</option>
      <option value="research_proposal" ${state.phase === 'research_proposal' ? 'selected' : ''}>Research / proposal</option>
    </select></label><label>Participation<select id="mode" ${state.pendingCreate ? 'disabled' : ''}>
      <option value="owner_only" ${state.mode === 'owner_only' ? 'selected' : ''}>Fusion only</option>
      <option value="requested_peers" ${state.mode === 'requested_peers' ? 'selected' : ''}>Requested peers</option>
    </select></label>${state.mode === 'requested_peers' ? `<fieldset><legend>Collaborate with</legend>${members.filter(item => ['kimi', 'deepseek'].includes(item.id)).map(item => `<label><input type="checkbox" data-peer="${item.id}" ${state.peers.includes(item.id) ? 'checked' : ''} ${state.pendingCreate ? 'disabled' : ''}>${item.name}</label>`).join('')}</fieldset>` : ''}</div>
  </details>`;
}

function taskComposer() {
  return `<form class="composer task-composer" id="task-form">
    <textarea id="task-draft" aria-label="Start a new task" placeholder="Start a new task in #${state.space}" maxlength="32000" required ${state.pendingCreate ? 'readonly' : ''}>${esc(state.draft)}</textarea>
    ${taskOptions()}<div class="composer-bottom"><small>One durable task per submission</small>
    <button class="send" aria-label="${state.pendingCreate ? 'Retry submission' : 'Create task'}" ${state.submitting ? 'disabled' : ''}>${state.pendingCreate ? 'Retry' : symbol('paperplane.fill')}</button></div>
  </form>`;
}

function taskList() {
  const tasks = visibleTasks();
  if (!tasks.length) return `<p class="empty">${state.loading ? 'Connecting to Workshop…' : state.tasks.length ? 'No matching tasks.' : 'No tasks yet. Start a task below; Fusion owns delivery by default.'}</p>`;
  return tasks.map(task => {
    const detail = state.details.get(task.id);
    return `<article class="task-card ${task.id === state.selected ? 'active' : ''}">${avatar()}<div>
      <b>You</b><time>${esc(dateText(task.createdAt))}</time>
      <button type="button" class="task-title" data-task="${esc(task.id)}">${esc(task.title)}</button>
      <p>${esc(task.brief)}</p><span class="label">${esc(label(task.state))}</span>
      <button type="button" class="reply-link" data-task="${esc(task.id)}"><span class="mini-people">${(detail?.participants ?? []).map(participant => { const person = member(participant.engineerID); return person ? avatar(person.initial, person.color, true) : ''; }).join('')}</span><b>Open conversation</b></button>
    </div></article>`;
  }).join('');
}

function conversation(task, detail) {
  const messages = state.messages.get(task.id) ?? [];
  const origin = detail?.ingress?.source === 'codex' ? 'From Codex · $team · ' : '';
  const mode = detail?.ingress?.request?.collaboration_mode;
  return `<div class="pinned">${symbol('pin.fill')}${esc(origin)}${mode === 'requested_peers' ? 'Collaboration requested' : mode === 'owner_only' || detail?.ingress?.request?.schema_version === 2 ? 'Owner task · Fusion owns delivery' : 'Legacy task'}</div>
    ${state.hasEarlier.get(task.id) ? button('earlier', 'Load earlier messages', state.earlierLoading ? 'Loading…' : 'Load earlier', 'text-link', state.earlierLoading) : ''}
    ${messages.length ? messages.map(message => {
      const name = authorName(message.author, message.structured);
      const person = member(String(message.author).replace('engineer:', ''));
      return `<article class="message" data-message-id="${esc(message.id)}">${avatar(person?.initial ?? (message.author === 'system' ? 'W' : 'Y'), authorColor(message.author))}<div><div><b>${esc(name)}</b><time>${esc(dateText(message.createdAt))}</time></div><p class="message-text">${esc(displayMessageBody(message))}</p></div></article>`;
    }).join('') : '<p class="empty">No committed messages loaded.</p>'}`;
}

function ownership(detail) {
  const requested = new Set((detail?.participants ?? []).map(item => item.engineerID));
  return `<h2>Delivery and participation</h2><p class="muted">Fusion owns delivery on new community tasks. Implementation assignments appear below.</p>
    ${members.map(person => `<div class="ownership-row">${avatar(person.initial, person.color)}<div><b>${person.name}</b><small>${person.role}</small></div><span class="status">${person.id === 'astra' ? 'Not connected' : requested.has(person.id) ? 'Participant' : 'Not requested'}</span></div>`).join('')}
    <div class="detail"><b>Writer enforcement not yet qualified</b><p>Assignments do not yet prove exclusive filesystem access or safe process handover.</p><small>Requested workspace: ${esc(detail?.ingress?.request?.workspace_ref ?? 'Not specified')}</small></div>
    ${(detail?.subtasks ?? []).map(subtask => `<div class="detail"><b>${esc(subtask.title)}</b><p>Assignee: ${esc(member(subtask.ownerID)?.name ?? 'Unassigned')} · ${esc(label(subtask.state))}</p></div>`).join('')}
    ${capacityPanel()}`;
}

function capacityPanel() {
  return `<h2>Team capacity</h2><p class="muted">Legacy per-engineer telemetry; shared account pools pending.</p><div class="capacity-table">${members.map(person => {
    const bucket = state.capacity?.[person.id];
    return `<div class="capacity-row"><b>${person.name}</b><span>${esc(label(bucket?.availability))}</span><small>Remaining: ${esc(bucket?.remaining ?? 'Unknown')} ${esc(bucket?.unit ?? '')}</small><small>Source: ${esc(bucket?.source ?? 'Not connected')} · Updated: ${esc(dateText(bucket?.observed_at) || 'Never')} · Reset: ${esc(dateText(bucket?.reset_at) || 'Unknown')}</small></div>`;
  }).join('')}</div>`;
}

function taskPanel(task, detail) {
  if (!task) return '<p class="empty">Choose a task to join its conversation.</p>';
  if (state.tab === 'Conversation') return conversation(task, detail);
  if (state.tab === 'Ownership') return ownership(detail);
  if (state.tab === 'Proposals') {
    const proposals = state.proposals.get(task.id) ?? [];
    return `<h2>Proposals</h2>${proposals.length ? proposals.map(proposal => {
      const content = parseProposal(proposal.content);
      return `<article class="proposal"><b>${esc(content?.title ?? 'Proposal')}</b><p>${esc(content?.summary ?? 'No summary')}</p><p class="message-text">${esc(content?.approach ?? '')}</p><small>${esc(member(proposal.author)?.name ?? proposal.author)} · ${esc(proposal.visibility)} · Revision ${esc(proposal.revision)}</small></article>`;
    }).join('') : '<p class="muted">No proposals have been recorded for this task.</p>'}`;
  }
  if (state.tab === 'Decisions') {
    const decisions = state.decisions.get(task.id) ?? [];
    return `<h2>Decisions</h2>${decisions.length ? decisions.map(decision => `<article class="decision">${symbol('checkmark.circle')}<div><b>${esc(label(decision.kind))}</b><p>${esc(decision.body)}</p><small>${esc(dateText(decision.createdAt))}</small></div></article>`).join('') : '<p class="muted">No decisions have been recorded for this task.</p>'}`;
  }
  const files = state.files.get(task.id) ?? [];
  return `<h2>Files and evidence</h2>${files.length ? files.map(file => `<article class="detail"><b>${esc(file.description ?? file.relativePath)}</b><small>${esc(file.mime ?? 'File')} · ${esc(file.validation)}</small><p>Revision: ${esc(file.baseRevision ?? 'Unknown')}</p></article>`).join('') : '<p class="muted">No task artifacts published yet.</p>'}<h2>Application asset</h2>${button('icon', 'View Workshop app icon', `${symbol('doc.text')}<span><b>Workshop app icon</b><small>Original woven-W asset · PNG</small></span>`, 'attachment')}`;
}

function replyComposer(task) {
  if (!task) return '';
  const uncertain = state.replyUncertain.has(task.id);
  return `<form class="composer reply-composer" id="reply-form" data-task-id="${esc(task.id)}">
    ${uncertain ? `<small role="alert">Delivery uncertain. Refresh the conversation before sending again.</small>${button('check-reply', 'Refresh conversation', 'Refresh conversation', 'text-link')}` : ''}
    <textarea id="reply-draft" aria-label="Reply to thread" placeholder="Reply to thread…" maxlength="32000" required>${esc(state.replyDrafts.get(task.id) ?? '')}</textarea>
    <div class="composer-bottom"><small>Reply to this task</small><button class="send" aria-label="Send reply" ${uncertain || state.replyPending.has(task.id) ? 'disabled' : ''}>${symbol('paperplane.fill')}</button></div>
  </form>`;
}

function render() {
  if (document.getElementById('icon-dialog')?.open) return;
  const focused = document.activeElement;
  const focusID = focused?.id;
  const selection = typeof focused?.selectionStart === 'number' ? [focused.selectionStart, focused.selectionEnd] : null;
  const scroll = ['task-scroll', 'thread-body'].map(className => [className, document.querySelector(`.${className}`)?.scrollTop ?? 0]);
  const task = selectedTask();
  const detail = state.details.get(state.selected);
  const visible = visibleTasks();
  root.innerHTML = `<div class="app"><header class="top"><div class="history">${button('prev', 'Previous task', symbol('arrow.left'), '', !visible.length)}${button('next', 'Next task', symbol('arrow.right'), '', !visible.length)}</div><label class="search">${symbol('magnifyingglass')}<input id="search" aria-label="Search Workshop" placeholder="Search Workshop" value="${esc(state.search)}"></label>${button('refresh', 'Refresh Workshop', symbol('arrow.right'))}${avatar('Y', 'user', true)}</header>
    <div class="layout"><nav class="rail" aria-label="App navigation">${button('icon', 'View Workshop app icon', '<img src="/assets/workshop-icon.png" class="brand" alt="Workshop">')}${button('home', 'Home', `${symbol('house.fill')}<span>Home</span>`)}${disabledNav('bubble.left.and.bubble.right', 'DMs')}${button('needs', 'Needs my input', `${symbol('bell')}<span>Activity</span>`)}${disabledNav('bookmark', 'Later')}${button('new', 'New task', symbol('plus'), 'add')}</nav>
    <aside class="sidebar"><div class="workspace-title"><b>Workshop</b>${symbol('chevron.down')}${button('new', 'Compose task', symbol('square.and.pencil'))}</div><div class="navlinks">${button('home', 'All tasks', `${symbol('list.bullet')}All tasks`)}${button('needs', 'Needs my input', `${symbol('bell')}Needs my input${state.tasks.filter(taskNeedsInput).length ? `<span class="count">${state.tasks.filter(taskNeedsInput).length}</span>` : ''}`)}${disabledNav('bookmark', 'Saved')}</div>
    <p class="section-label">TASK SPACES ${symbol('chevron.down')}</p>${['engineering', 'research', 'product', 'projects'].map(space => button(`space:${space}`, space, `${symbol('number')}${space}`, `space ${space === state.space ? 'selected' : ''}`)).join('')}
    <p class="section-label">ENGINEERS ${symbol('chevron.down')}</p>${members.map(person => `<div class="engineer"><span class="presence ${probe(person.id)?.health?.kind === 'available' ? person.color : 'unknown'}"></span><span>${person.name}<small>${person.id === 'astra' ? 'Not connected' : probe(person.id)?.effectiveModel === 'fake-model' ? 'Test adapter' : esc(label(probe(person.id)?.health?.kind))}</small></span>${person.id === 'astra' ? symbol('display') : ''}</div>`).join('')}${button('capacity', 'Team capacity', 'Team capacity', 'capacity-link')}<div class="account">${avatar()}<div><b>You</b><small>Local workspace</small></div>${symbol('ellipsis')}</div></aside>
    <section class="task-column"><div class="column-head"><h1>${symbol('number')} ${state.space}</h1><p>Every message starts a task</p><div class="subtabs"><b>Messages</b>${button('tab:Files', 'Files', 'Files')}${button('new', 'Add task', symbol('plus'))}</div></div><div class="connection-status" role="status">${testAdapters() ? 'Test adapters · persisted local data · ' : ''}${state.connected ? 'Connected' : 'Disconnected · reconnecting'}</div><div class="task-scroll">${taskList()}</div>${taskComposer()}</section>
    <section class="thread">${state.threadOpen ? `<div class="thread-head"><div><h1>Thread</h1><p>${task ? esc(task.title) : 'Choose a task'}</p></div><span>${button('close-thread', 'Close thread', symbol('xmark'))}</span></div><div class="thread-tabs" role="tablist" aria-label="Task details">${tabs.map(tab => `<button type="button" id="tab-${tab}" role="tab" aria-selected="${state.tab === tab}" aria-controls="task-panel" tabindex="${state.tab === tab ? '0' : '-1'}" class="${state.tab === tab ? 'active' : ''}" data-action="tab:${tab}">${tab}</button>`).join('')}</div>${task ? `<div id="task-activity" class="task-activity" role="status" aria-live="polite">${activityMarkup(task, detail)}</div>` : ''}${task ? '<div id="activity-history-container" class="activity-history-container"></div>' : ''}<div class="thread-body" id="task-panel" role="tabpanel" aria-labelledby="tab-${state.tab}" tabindex="0">${task ? taskPanel(task, detail) : state.tab === 'Ownership' ? capacityPanel() : '<div class="empty-thread"><h2>Your work, in one conversation</h2><p>Select a task or start one to see committed replies, proposals, decisions, and evidence.</p></div>'}</div>${replyComposer(task)}` : `<div class="empty-thread"><h2>Choose a task to open its conversation</h2>${button('open-thread', 'Open conversation', 'Open conversation', 'text-link')}</div>`}</section>
    </div>${state.error ? `<div class="toast" role="alert">${esc(state.error)}${button('dismiss', 'Dismiss notice', symbol('xmark'))}</div>` : ''}</div>
    <dialog id="icon-dialog" aria-labelledby="icon-title"><button type="button" class="close" data-action="close-icon" aria-label="Close details">${symbol('xmark')}</button><img class="icon-preview" src="/assets/workshop-icon.png" alt="Workshop woven W app icon"><h2 id="icon-title">Workshop</h2><p>Original interwoven ribbon mark in aubergine, lavender and mint.</p></dialog>`;
  updateActivityHistory();
  for (const [className, top] of scroll) { const element = document.querySelector(`.${className}`); if (element) element.scrollTop = top; }
  const replacement = focusID ? document.getElementById(focusID) : null;
  if (replacement) { replacement.focus({ preventScroll: true }); if (selection && replacement.setSelectionRange) replacement.setSelectionRange(...selection); }
  document.getElementById('task-options')?.addEventListener('toggle', event => { state.optionsOpen = event.target.open; });
  document.getElementById('icon-dialog')?.addEventListener('close', () => { render(); document.querySelector(dialogOpener)?.focus(); });
}

async function loadSelected() {
  const id = state.selected;
  if (!id) return;
  const generation = ++selectionGeneration;
  const observedAt = Date.now();
  void loadActivity(id);
  const results = await Promise.allSettled([api.getTask(id), api.getMessages(id), api.getProposals(id), api.getDecisions(id), api.getFiles(id)]);
  if (id !== state.selected || generation !== selectionGeneration) return;
  const caches = [state.details, state.messages, state.proposals, state.decisions, state.files];
  results.forEach((result, index) => {
    if (result.status === 'fulfilled') {
      if (index === 1) {
        state.messages.set(id, mergeMessages(state.messages.get(id) ?? [], result.value));
        const messages = state.messages.get(id);
        state.hasEarlier.set(id, messages.length > 0 && messages[0].seq > 1);
      } else {
        if (index !== 0 || (state.activityObserved.get(id) ?? 0) <= observedAt) {
          caches[index].set(id, result.value);
          if (index === 0 && state.connected) state.activityObserved.set(id, observedAt);
        }
      }
    } else {
      if (index === 0) state.activityObserved.delete(id);
      state.error = 'Some task details could not be loaded. Refresh to retry.';
    }
  });
  render();
  return results[1].status === 'fulfilled';
}

async function refresh(withProfiles = false) {
  const generation = ++refreshGeneration;
  try {
    const tasks = await api.listTasks();
    if (generation !== refreshGeneration) return;
    state.tasks = tasks;
    state.loading = false;
    if (!state.selected || !tasks.some(task => task.id === state.selected)) state.selected = tasks[0]?.id ?? null;
    render();
    await loadSelected();
    if (withProfiles || Date.now() - profileObservedAt > 300000) {
      profileObservedAt = Date.now();
      const [engineers, capacity] = await Promise.allSettled([api.getEngineers(), api.getCapacity()]);
      if (engineers.status === 'fulfilled') state.engineers = engineers.value;
      if (capacity.status === 'fulfilled') state.capacity = capacity.value;
      render();
    }
  } catch {
    state.loading = false;
    state.error = 'Workshop is unavailable. Your drafts are preserved; refresh to reconnect.';
    render();
  }
}

function selectTask(id) {
  state.selected = id;
  state.tab = 'Conversation';
  state.threadOpen = true;
  render();
  void loadSelected();
}

async function createTask() {
  if (state.submitting) return;
  if (!state.pendingCreate) {
    if (state.mode === 'requested_peers' && !state.peers.length) { state.error = 'Select at least one requested peer.'; render(); return; }
    state.pendingCreate = buildTaskPayload({ draft: state.draft, phase: state.phase, mode: state.mode, peers: state.peers, channel: state.space, uuid: crypto.randomUUID() });
  }
  state.submitting = true;
  render();
  let receipt;
  try {
    receipt = await api.createTask(state.pendingCreate);
    if (typeof receipt?.task_id !== 'string' || !receipt.task_id.startsWith('task_')) throw new Error('Missing receipt');
  } catch (error) {
    if (error.status === 400) { state.pendingCreate = null; state.error = error.message; }
    else state.error = 'Delivery uncertain. Retry this submission to check its receipt.';
    state.submitting = false;
    render();
    return;
  }
  state.submitting = false;
  state.pendingCreate = null;
  state.draft = '';
  state.phase = 'execution';
  state.mode = 'owner_only';
  state.peers = [];
  state.optionsOpen = false;
  state.error = '';
  state.view = 'all';
  state.search = '';
  state.selected = receipt.task_id;
  state.tab = 'Conversation';
  state.threadOpen = true;
  render();
  await refresh();
}

async function postReply(id) {
  if (!id || state.replyPending.has(id) || state.replyUncertain.has(id)) return;
  const body = (state.replyDrafts.get(id) ?? '').trim();
  if (!body) return;
  state.replyPending.add(id);
  render();
  try {
    const message = await api.postMessage(id, body);
    if (typeof message?.id !== 'string') throw new Error('Missing message receipt');
    if ((state.replyDrafts.get(id) ?? '').trim() === body) state.replyDrafts.set(id, '');
    state.messages.set(id, mergeMessages(state.messages.get(id) ?? [], [message]));
    state.error = '';
  } catch (error) {
    if (error.status !== 400) state.replyUncertain.add(id);
    state.error = error.status === 400 ? error.message : 'Delivery uncertain. Refresh the conversation before sending again.';
  } finally {
    state.replyPending.delete(id);
    render();
  }
}

async function earlier() {
  const id = state.selected;
  const first = state.messages.get(id)?.[0]?.seq;
  if (!first || state.earlierLoading) return;
  state.earlierLoading = true;
  render();
  try {
    const page = await api.getMessages(id, first);
    state.messages.set(id, mergeMessages(state.messages.get(id) ?? [], page));
    state.hasEarlier.set(id, page.length > 0 && state.messages.get(id)[0].seq > 1);
  } catch { state.error = 'Earlier messages could not be loaded.'; }
  finally { state.earlierLoading = false; render(); }
}

root.addEventListener('input', event => {
  const element = event.target;
  if (element.id === 'search') { state.search = element.value; render(); }
  if (element.id === 'task-draft' && !state.pendingCreate) state.draft = element.value;
  if (element.id === 'reply-draft' && state.selected) state.replyDrafts.set(state.selected, element.value);
});
root.addEventListener('change', event => {
  const element = event.target;
  if (element.id === 'phase') state.phase = element.value;
  if (element.id === 'mode') { state.mode = element.value; render(); }
  if (element.dataset.peer) state.peers = element.checked ? [...new Set([...state.peers, element.dataset.peer])] : state.peers.filter(id => id !== element.dataset.peer);
});
root.addEventListener('submit', event => {
  event.preventDefault();
  if (event.target.id === 'task-form') void createTask();
  if (event.target.id === 'reply-form') void postReply(event.target.dataset.taskId);
});
root.addEventListener('keydown', event => {
  if (event.target.getAttribute('role') !== 'tab' || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  event.preventDefault();
  const current = tabs.indexOf(state.tab);
  state.tab = event.key === 'Home' ? tabs[0] : event.key === 'End' ? tabs.at(-1) : tabs[(current + (event.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
  render();
  document.getElementById(`tab-${state.tab}`).focus();
});
root.addEventListener('click', async event => {
  const element = event.target.closest('button');
  if (!element || element.disabled) return;
  if (element.dataset.task) { selectTask(element.dataset.task); return; }
  const [action, value] = (element.dataset.action ?? '').split(':');
  if (!action) return;
  if (action === 'new') { document.getElementById('task-draft').focus(); return; }
  if (action === 'icon') {
    dialogOpener = '[data-action="icon"]';
    document.getElementById('icon-dialog').showModal();
    return;
  }
  if (action === 'close-icon') { document.getElementById('icon-dialog').close(); return; }
  if (action === 'refresh') { state.error = ''; await refresh(true); return; }
  if (action === 'earlier') { await earlier(); return; }
  if (action === 'check-reply') {
    const id = state.selected;
    if (await loadSelected()) { state.replyUncertain.delete(id); state.error = 'Conversation refreshed. Check whether your previous reply arrived before sending.'; }
  }
  if (action === 'tab') { state.tab = value; state.threadOpen = true; }
  if (action === 'more-activity') { void loadActivity(state.selected); return; }
  if (action === 'capacity') { state.tab = 'Ownership'; state.threadOpen = true; }
  if (action === 'close-thread') state.threadOpen = false;
  if (action === 'open-thread') state.threadOpen = true;
  if (action === 'home') { state.view = 'all'; state.search = ''; }
  if (action === 'needs') state.view = 'needs';
  if (action === 'space') { state.space = value; state.view = 'space'; }
  if (action === 'dismiss') state.error = '';
  if (action === 'prev' || action === 'next') {
    const visible = visibleTasks();
    const index = visible.findIndex(task => task.id === state.selected);
    const next = visible[Math.max(0, Math.min(visible.length - 1, index + (action === 'next' ? 1 : -1)))];
    if (next) { selectTask(next.id); return; }
  }
  render();
});

render();
void refresh(true);
const unsubscribe = api.subscribe(event => {
  if (event.type === 'connection') {
    const wasConnected = state.connected;
    state.connected = event.connected === true;
    if (!state.connected) state.activityObserved.clear();
    render();
    if (!state.connected || wasConnected) return;
  }
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => { void refresh(); }, 100);
});
const activityTimer = setInterval(() => { void pollActivity(); }, 5000);
window.addEventListener('pagehide', () => { unsubscribe(); clearTimeout(refreshTimer); clearInterval(activityTimer); });
