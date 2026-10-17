#!/bin/sh
# 가드 검사. 로컬 훅과 GitHub CI가 같은 이 스크립트를 쓴다.
#   sh scripts/guard.sh staged        커밋하려는 파일 검사 (pre-commit)
#   sh scripts/guard.sh range <base>  <base> 이후 바뀐 파일과 커밋 메시지 검사 (pre-push, CI)
# 걸리면 우회하지 말고 메시지대로 고친다. (AGENTS.md 3절)

mode=$1
base=$2
MAX_BYTES=5242880   # 5MB
IFS='
'
errors=""
fail() { errors="$errors
- $1"; }

if [ "$mode" = "staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
  content() { git show ":$1" 2>/dev/null; }
  size() { git cat-file -s ":$1"; }
  msgs=""
  has_prd() { git cat-file -e :PRD.md 2>/dev/null || [ -f PRD.md ]; }
elif [ "$mode" = "range" ] && [ -n "$base" ]; then
  files=$(git diff --name-only --diff-filter=ACMR "$base"...HEAD)
  content() { cat "$1" 2>/dev/null; }
  size() { wc -c < "$1" | tr -d ' '; }
  msgs=$(git log --no-merges --format=%s "$base"..HEAD)
  has_prd() { [ -f PRD.md ]; }
else
  echo "사용법: sh scripts/guard.sh staged | range <base>"; exit 2
fi

# 비밀 값 패턴: 실제 키처럼 생긴 값만 잡는다.
SECRET_RE='sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
ASSIGN_RE='(api[_-]?key|secret|token|passw(or)?d|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]]{8,}["'"'"']'

for f in $files; do
  [ "$f" = "scripts/guard.sh" ] && continue

  # 1. 환경값 파일 (.env.example만 허용)
  case "$f" in
    *.env.example) ;;
    .env|*/.env|.env.*|*/.env.*|*.pem|*.key|*.p12|id_rsa*|*/id_rsa*)
      fail "비밀 정보 파일: $f — 커밋에서 빼고 .gitignore에 있는지 확인하세요." ;;
  esac

  # 2. 큰 파일
  s=$(size "$f")
  [ "${s:-0}" -gt "$MAX_BYTES" ] && fail "5MB 넘는 파일: $f ($s bytes) — 큰 파일은 GitHub에 올리지 않습니다."

  # 3. 코드 안의 API 키·비밀번호
  hit=$(content "$f" | grep -I -n -E "$SECRET_RE" | head -n 3)
  [ -z "$hit" ] && hit=$(content "$f" | grep -I -n -i -E "$ASSIGN_RE" | head -n 3)
  if [ -n "$hit" ]; then
    lines=$(printf '%s\n' "$hit" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
    fail "API 키·비밀번호로 보이는 값: $f (${lines}번째 줄) — 값은 .env로 옮기고 코드에서는 환경변수로 읽으세요."
  fi
done

# 4. PRD 없이 코드 금지
if ! has_prd; then
  for f in $files; do
    case "$f" in
      *.md|.githooks/*|.github/*|.claude/*|scripts/guard.sh|.gitignore) ;;
      *) fail "PRD.md가 없는데 코드가 들어왔습니다: $f — PRD를 먼저 만드세요. (AGENTS.md 1절)" ;;
    esac
  done
fi

# 5. 허용 목록에 없는 문서
for f in $(git ls-files --cached '*.md'); do
  ok=""
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    case "$f" in $pat) ok=1; break ;; esac
  done < .githooks/allowed-docs.txt
  [ -z "$ok" ] && fail "허용 목록에 없는 문서: $f — 기존 문서에 넣거나, 사용자 승인 후 .githooks/allowed-docs.txt에 추가하세요."
done

# 6. 커밋 메시지 형식 (range 모드)
for m in $msgs; do
  printf '%s' "$m" | grep -Eq '^(feat|fix|docs|refactor|test|chore)(\([^)]+\))?: .+|^Revert' \
    || fail "커밋 메시지 형식 오류: \"$m\" — '종류: 무엇을 했는지' 형식이어야 합니다."
done

if [ -n "$errors" ]; then
  echo "가드 검사 실패:$errors"
  echo
  echo "우회(--no-verify)하지 말고 위 내용을 고친 뒤 다시 시도하세요."
  exit 1
fi
echo "가드 검사 통과"
