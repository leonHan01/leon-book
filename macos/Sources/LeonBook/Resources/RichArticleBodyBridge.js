// Publish edits immediately, but send only the changed serialized block span.
// Offsets use UTF-16, shared by JavaScript strings and NSString on the native side.
function createArticleBodyBridge(send) {
  let bodyLength = 0, parts = null, sessionID = '', revision = 0;
  function reset(source, canonical, fragments, session) {
    bodyLength = source.length; parts = source === canonical ? fragments : null;
    sessionID = session; revision = 0;
  }
  function publish(fragments, forceFull = false) {
    const message = { type: 'change', sessionID, baseRevision: revision, revision: revision + 1 };
    let nextLength;
    if (!forceFull && parts) {
      let first = 0, offset = 0, oldEnd = parts.length, newEnd = fragments.length;
      while (first < oldEnd && first < newEnd && parts[first] === fragments[first]) {
        offset += parts[first].length; first++;
      }
      if (first === oldEnd && first === newEnd) return false;
      while (oldEnd > first && newEnd > first && parts[oldEnd - 1] === fragments[newEnd - 1]) { oldEnd--; newEnd--; }
      let removedLength = 0, insertedLength = 0;
      for (let index = first; index < oldEnd; index++) removedLength += parts[index].length;
      for (let index = first; index < newEnd; index++) insertedLength += fragments[index].length;
      nextLength = bodyLength - removedLength + insertedLength;
      if (insertedLength + 160 < nextLength) {
        message.patch = { offset, removedLength, text: fragments.slice(first, newEnd).join(''), baseLength: bodyLength };
      }
    }
    if (!message.patch) { message.body = fragments.join(''); nextLength = message.body.length; }
    send(message);
    bodyLength = nextLength; parts = fragments; revision++;
    return true;
  }
  return { reset, publish };
}
