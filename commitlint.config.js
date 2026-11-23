const identifierPrefixedSubject =
  /^(?:build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(?:\([^)]*\))?: [A-Z][A-Z0-9]*-[0-9]+ /

const config = { extends: ['@commitlint/config-conventional'] }

// Allow subjects that open with a review-finding or ticket identifier
// (e.g. "docs(airgap): C-3 becomes ..."): the leading capital makes
// the subject-case matcher report sentence-case. The pattern still
// requires a conventional type and an uppercase identifier, so
// ordinary sentence-case subjects keep failing.
config.ignores = [(message) => identifierPrefixedSubject.test(message)]

module.exports = config
