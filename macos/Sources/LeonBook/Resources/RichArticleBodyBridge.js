// Publish edits immediately, but send only the changed serialized block span.
// Offsets use UTF-16, shared by JavaScript strings and NSString on the native side.
function createArticleBodyBridge(send) {
  let body = '', parts = null, sessionID = '', revision = 0;
  function reset(source, canonical, fragments, session) {
    body = source; parts = source === canonical ? fragments : null;
    sessionID = session; revision = 0;
  }
  function publish(next, fragments, forceFull = false) {
    if (!forceFull && next === body) return false;
    const message = { type: 'change', sessionID, baseRevision: revision, revision: revision + 1 };
    if (!forceFull && parts) {
      let first = 0, offset = 0, oldEnd = parts.length, newEnd = fragments.length;
      while (first < oldEnd && first < newEnd && parts[first] === fragments[first]) {
        offset += parts[first].length; first++;
      }
      while (oldEnd > first && newEnd > first && parts[oldEnd - 1] === fragments[newEnd - 1]) { oldEnd--; newEnd--; }
      let removedLength = 0;
      for (let index = first; index < oldEnd; index++) removedLength += parts[index].length;
      const text = fragments.slice(first, newEnd).join('');
      if (text.length + 160 < next.length) message.patch = { offset, removedLength, text, baseLength: body.length };
    }
    if (!message.patch) message.body = next;
    send(message);
    body = next; parts = fragments; revision++;
    return true;
  }
  return { reset, publish };
}
