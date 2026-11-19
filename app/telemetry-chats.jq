def r1:
  gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[removed]")
  | gsub("(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|tk_[a-z0-9]{29}|glpat-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,})"; "[removed]")
  | gsub("(?<k>(?i:password|passwd|secret|token|api[_-]?key)\\s*[:=]\\s*)[\"']?[^\\s\"']+[\"']?"; "\(.k)[removed]")
  | gsub("(?<s>://)[^/\\s:@]+:[^/\\s@]+@"; "\(.s)[removed]@");

def s1:
  [(.sources // [])[] | (.source.name // empty), ((.metadata // [])[] | (.name // .source // empty))]
  | map(select(type == "string")) | unique;

.[] | select((.updated_at // 0) > $s) | .id as $c
| {
    id, title, created_at, updated_at, user: "friend",
    models: (.chat.models // []),
    messages: ((.chat.history.messages // {}) | [.[] | {
      id, parent: .parentId, children: (.childrenIds // []), role, timestamp, model,
      content: (.content // ""), error: (.error // null), done: (.done // null),
      usage: (.usage // .info.usage // null), sources: s1,
      files: [(.files // [])[] | (.name // .file.filename // .file.meta.name // "file")],
      rating: (.annotation.rating // null)
    }] | sort_by(.timestamp // 0)),
    feedback: [($b[0] // [])[]? | select(.meta.chat_id == $c) | {
      message: .meta.message_id, rating: .data.rating, reason: (.data.reason // null),
      comment: (.data.comment // null), created_at
    }]
  }
| walk(if type == "string" then r1 else . end)
