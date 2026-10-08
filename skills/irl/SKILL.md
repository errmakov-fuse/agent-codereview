---
name: irl
description: Use when the user invokes /irl with a quote, or says a question, claim, statement or declared problem is too abstract and asks to see it in real life - "show me an example", "what does that look like in practice", "I don't get what you mean", "what is the difference".
argument-hint: "<quote to illustrate>"
---

# IRL

## Overview

The user quoted something and cannot picture it. Show them one concrete case in which the quoted thing visibly happens. The reply is that case and nothing after it.

Quote to illustrate: $ARGUMENTS

## The Reply

The reply has exactly these parts, in this order.

1. **What it says** - one sentence restating the quote in plain words, with any pronoun or jargon replaced by the thing it refers to in this conversation.
2. **The case** - one specific instance, walked through in the order it happens: the starting state, the event, what each component does, what a person would observe at the end. Every noun is a named thing with a value: this URL, these three rows, this timeout, this log line. Use the same system, tables, files and names the conversation is about.
3. **The point** - one sentence tying the last step of the case back to the quote. The reply ends here.

Size: the whole reply fits on one screen. A small table or a short code block is welcome when it shows state before and after.

## Which Case to Use

| Situation | Case |
|---|---|
| A real instance is already in the conversation, or one or two lookups would find it (a row, a log line, a `file:line`) | That instance, with where it came from |
| No real instance is within reach | A constructed one, opened with the word "Illustrative:" and stating which values are real and which are made up |
| The quote is a question offering options | One case run once under each option, ending where the outcomes differ |
| The quote is a problem statement | The case in which the problem bites, ending on the visible damage |
| The quote is not from this conversation | Treat it as a standalone statement and construct the case |
| The quote has two plausible readings | Pick the one the conversation supports and say which in part 1 |

## Example

Quote: "should the retry cap of 3 apply per resource row or per URL?"

> **What it says:** when the same file has several rows, do they each get 3 download tries, or do they share 3?
>
> **The case** (Illustrative: the URL is made up, the schema is ours). `acme.com/whitepaper.pdf` is linked from three pages, so `resources` has rows A, B and C for it. The file is dead on acme's server.
>
> | Cap | What happens | Requests to acme |
> |---|---|---|
> | Per row | A fails 3 times, then B 3 times, then C 3 times | 9 |
> | Per URL | A fails twice, B once, the URL is exhausted, C is never tried | 3 |
>
> **The point:** the two options differ only for URLs with more than one row, and there the choice is 9 requests against 3.

## Common Mistakes

| Mistake | Instead |
|---|---|
| Carrying on into a fix, a recommendation, trade-offs or a related case | Those are a separate reply, given when the user asks for it |
| An everyday analogy (a bouncer, a restaurant, a post office) | The case stays inside the system under discussion |
| Several small examples | One case, followed all the way through |
| Made-up values presented as observed | "Illustrative:" plus which values are real |
| Explaining the mechanism in general terms again | Named things with values, in time order |
