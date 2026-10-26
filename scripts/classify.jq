# Classifies the open PRs listed by `gh pr list`. lib.sh prepends the bindings
# for $me, $watched, $skip_keywords, $review_drafts and $rereview_dismissed and
# passes the whole text to gh --jq.
#
# Output, one line per PR that needs action:
#   MINE <n>                                 my PR, nobody requested, nobody else reviewed
#   THEIRS <n>                               a watched author's PR with no review from me
#   REREVIEW <n> <head> <reason> <reviewed>  a watched author's PR that moved past my review
#
# <reason> is rerequested, changes_requested or dismissed. <reviewed> is the
# commit my last review was submitted on ("unknown" when GitHub no longer has it).
#
# Skipped: any PR whose title contains one of $skip_keywords (plain text, case
# ignored); my own drafts; and a watched author's draft unless my review is
# requested on it or $review_drafts is on.
#
# A changes_requested or dismissed re-review also waits until the CI checks on
# the head have finished, and is not reported while any of them failed: the
# author has more to fix, and a review now would be spent on a moving target.
# A re-request is reported whatever the checks say.

# Each check on the head as one word: PENDING while it runs, else its outcome.
def check_states:
  [(.statusCheckRollup // [])[]
   | if .__typename == "StatusContext" then (.state // "PENDING")
     elif (.status // "COMPLETED") != "COMPLETED" then "PENDING"
     else (.conclusion // "") end];

def checks_settled:
  check_states
  | (any(. == "PENDING" or . == "EXPECTED")
     or any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT"
            or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE"))
  | not;

.[]
| ((.title // "") | ascii_downcase) as $title
| select($skip_keywords | any(. as $keyword | $title | contains($keyword | ascii_downcase)) | not)
| . as $pr
| ($pr.author.login // "") as $author
| [$pr.reviews[] | (.author.login // "")] as $reviewers
| ([$pr.reviewRequests[] | (.login // "")] | any(. as $login | $me | any(. == $login))) as $asked
| if $me | any(. == $author) then
    (if ($pr.isDraft | not) and ($pr.reviewRequests | length) == 0 and (($reviewers - $me) | length) == 0
     then "MINE \($pr.number)"
     else empty end)
  elif $watched | any(. == $author) then
    if $pr.isDraft and ($review_drafts | not) and ($asked | not) then
      empty
    else
      ([$pr.reviews[] | select((.author.login // "") as $login | $me | any(. == $login))]
       | sort_by(.submittedAt)) as $mine
      | if ($mine | length) == 0 then
          "THEIRS \($pr.number)"
        else
          # A reply in a review thread is a COMMENTED review, so the verdict is my
          # last review that is not one; only if there is none does a comment count.
          (([$mine[] | select(.state != "COMMENTED")] | last) // ($mine | last)) as $last
          | ($last.commit.oid // "unknown") as $reviewed
          | if $reviewed == $pr.headRefOid then
              empty
            elif $asked then
              "REREVIEW \($pr.number) \($pr.headRefOid) rerequested \($reviewed)"
            elif ($pr | checks_settled | not) then
              empty
            elif $last.state == "CHANGES_REQUESTED" then
              "REREVIEW \($pr.number) \($pr.headRefOid) changes_requested \($reviewed)"
            elif $last.state == "DISMISSED" and $rereview_dismissed then
              "REREVIEW \($pr.number) \($pr.headRefOid) dismissed \($reviewed)"
            else
              empty
            end
        end
    end
  else
    empty
  end
