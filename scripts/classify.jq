# Classifies the open PRs listed by `gh pr list`. lib.sh prepends the bindings
# for $me, $watched, $skip_keywords and $rereview_dismissed and passes the whole
# text to gh --jq.
#
# Output, one line per PR that needs action. Drafts are skipped, and so is any
# PR whose title contains one of $skip_keywords (plain text, case ignored):
#   MINE <n>                                 my PR, nobody requested, nobody else reviewed
#   THEIRS <n>                               a watched author's PR with no review from me
#   REREVIEW <n> <head> <reason> <reviewed>  a watched author's PR that moved past my review
#
# <reason> is rerequested, changes_requested or dismissed. <reviewed> is the
# commit my last review was submitted on (missing when GitHub no longer has it).

.[]
| select(.isDraft | not)
| ((.title // "") | ascii_downcase) as $title
| select($skip_keywords | any(. as $keyword | $title | contains($keyword | ascii_downcase)) | not)
| . as $pr
| ($pr.author.login // "") as $author
| [$pr.reviews[] | (.author.login // "")] as $reviewers
| if $me | any(. == $author) then
    (if ($pr.reviewRequests | length) == 0 and (($reviewers - $me) | length) == 0
     then "MINE \($pr.number)"
     else empty end)
  elif $watched | any(. == $author) then
    ([$pr.reviews[] | select((.author.login // "") as $login | $me | any(. == $login))]
     | sort_by(.submittedAt)) as $mine
    | if ($mine | length) == 0 then
        "THEIRS \($pr.number)"
      else
        # A reply in a review thread is a COMMENTED review, so the verdict is my
        # last review that is not one; only if there is none does a comment count.
        (([$mine[] | select(.state != "COMMENTED")] | last) // ($mine | last)) as $last
        | ($last.commit.oid // "") as $reviewed
        | ([$pr.reviewRequests[] | (.login // "")] | any(. as $login | $me | any(. == $login))) as $asked
        | if $reviewed == $pr.headRefOid then
            empty
          elif $asked then
            "REREVIEW \($pr.number) \($pr.headRefOid) rerequested \($reviewed)"
          elif $last.state == "CHANGES_REQUESTED" then
            "REREVIEW \($pr.number) \($pr.headRefOid) changes_requested \($reviewed)"
          elif $last.state == "DISMISSED" and $rereview_dismissed then
            "REREVIEW \($pr.number) \($pr.headRefOid) dismissed \($reviewed)"
          else
            empty
          end
      end
  else
    empty
  end
