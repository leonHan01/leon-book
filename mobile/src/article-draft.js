export function autosaveArticleDraft(snapshot, persist, status, restored) {
  let timer, writing, revision = 0, savedRevision = 0, paused = false;
  status(restored ? '已恢复本地草稿' : '编辑时会自动保存草稿');

  async function flush() {
    clearTimeout(timer);
    try {
      while (!paused && savedRevision < revision) {
        if (!writing) {
          const current = revision;
          writing = Promise.resolve().then(() => persist(snapshot())).then(() => {
            savedRevision = current;
          }).finally(() => { writing = null; });
        }
        await writing;
      }
      if (!paused && revision) status('草稿已自动保存');
      return true;
    } catch {
      status('草稿自动保存失败，请重试或使用「保存文章」。', true);
      return false;
    }
  }

  return {
    changed() {
      revision++;
      status('正在保存草稿…');
      clearTimeout(timer);
      timer = setTimeout(flush, 400);
    },
    flush,
    async settle() {
      paused = true;
      clearTimeout(timer);
      if (writing) await writing.catch(() => {});
    },
    resume() {
      paused = false;
      if (savedRevision < revision) timer = setTimeout(flush, 400);
    },
  };
}
