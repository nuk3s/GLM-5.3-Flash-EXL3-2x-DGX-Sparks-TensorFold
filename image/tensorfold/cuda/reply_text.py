"""The CUDA server's reply text: streamed decoding, think blocks and tool-call parsing (the Mac lane server's rules).

Parts adapted from jayleaton/glm53-tensorfold-spark patch 0620 (Apache-2.0): the rule that calls written inside the
think block are the reply's calls when they end it (its ``trailing_calls``), in ``ThinkSplit``.
"""

from __future__ import annotations

import json
import os
import re
import uuid
from typing import Any

from tensorfold.server.stopping import StopPolicy
from tensorfold.server.tools import _GLM_NAME_RE as _GLM_NAME, parse_glm_tool_call_block
from tensorfold.tool_parameters import decode_parameter, nullable_text, parameter_schemas, typed_parameter

_CALL_OPEN, _CALL_CLOSE = "<tool_call>", "</tool_call>"
_TOOL_CALL_BLOCK_RE = re.compile(r"<tool_call>\s*(.*?)\s*</tool_call>", re.IGNORECASE | re.DOTALL)
_CALL_OPEN_RE = re.compile(re.escape(_CALL_OPEN), re.IGNORECASE)
_QWEN_HEAD = "<function="
_HEAD_WINDOW = 512          # characters after an opener that decide whether it is a call's (a name, then a tag)


def _call_head(text: str, at: int) -> bool:
    """Whether the text after a ``<tool_call>`` (from ``at``) begins as a call or may still: GLM's name then
    ``<arg_key>`` or ``</tool_call>``, Qwen's ``<function=``, or JSON. A tag the text only mentions (``the literal
    `<tool_call>` markup``) does not, and is text: the block a call's markup makes starts at the call's own opener.
    A call without arguments is ``<tool_call>name</tool_call>``, as the chat template writes it: a word the tags
    enclose with space (``<tool_call> name </tool_call>``) is prose naming them."""

    rest = text[at:at + _HEAD_WINDOW]
    spaced, rest = rest[:1].isspace(), rest.lstrip()
    if not rest or rest[0] in "{[" or rest.startswith(_QWEN_HEAD) or _QWEN_HEAD.startswith(rest):
        return True
    name = _GLM_NAME.match(rest)
    if name is None:
        return False
    after = rest[name.end():].lstrip()
    return any(after.startswith(tag) or tag.startswith(after) for tag in ((_KEY,) if spaced else (_KEY, _CALL_CLOSE)))


def _call_blocks(text: str):
    """``_TOOL_CALL_BLOCK_RE``'s matches, each from an opener ``_call_head`` takes for a call's (mentions skipped)."""

    pos = 0
    while (opener := _CALL_OPEN_RE.search(text, pos)) is not None:
        pos = opener.end()
        if not _call_head(text, pos):
            continue
        block = _TOOL_CALL_BLOCK_RE.match(text, opener.start())
        if block is None:
            return
        yield block
        pos = block.end()
_TOOL_FUNCTION_BLOCK_RE = re.compile(r"^\s*<function=([^>\s]+)>\s*(.*?)\s*</function>\s*$", re.IGNORECASE | re.DOTALL)
_TOOL_PARAMETER_BLOCK_RE = re.compile(r"<parameter=([^>\s]+)>\n?(.*?)\n?</parameter>", re.IGNORECASE | re.DOTALL)



def _partial_tag(text: str, tag: str) -> int:
    for k in range(min(len(tag) - 1, len(text)), 0, -1):
        if text.endswith(tag[:k]):
            return k
    return 0


class StreamDecoder:
    """Decode a shared token window to preserve leading spaces and byte boundaries, deferring incomplete characters."""

    def __init__(self, tok, skip: tuple[int, ...] = ()):
        self.tok, self.skip = tok, frozenset(skip)
        self.ids: list[int] = []
        self.text = ""
        self.prefix = 0             # window start
        self.read = 0               # tokens already reflected in ``text``

    def _decode(self, ids: list[int]) -> str:
        return self.tok.decode(ids, skip_special_tokens=False)

    def add(self, new: list[int]) -> str:
        self.ids.extend(t for t in new if t not in self.skip)
        before = self._decode(self.ids[self.prefix:self.read])
        after = self._decode(self.ids[self.prefix:])
        if len(after) > len(before) and not after.endswith("\ufffd"):
            self.text += after[len(before):]
            self.prefix, self.read = self.read, len(self.ids)
        return self.text

    def final(self) -> str:
        """Everything, including a trailing partial character (as decoding it all at once gives)."""

        before = self._decode(self.ids[self.prefix:self.read])
        return self.text + self._decode(self.ids[self.prefix:])[len(before):]



class StopStrings:
    """A request's ``stop`` strings, decided token by token, so a reply cuts at the same token however its tokens arrive."""

    def __init__(self, strings: tuple[str, ...], tok, skip: tuple[int, ...] = ()):
        self.strings, self.tok, self.skip = strings, tok, frozenset(skip)
        # a new match lies in the last (its UTF-8 length) tokens, plus eight as the Mac's ``StopPolicy`` keeps
        self.tail = max((len(s.encode()) for s in strings), default=0) + 8

    def hit(self, tokens: list[int]) -> bool:
        """Whether the text through the newest token holds a stop string (earlier tokens were checked already)."""

        ids = [t for t in tokens[-self.tail:] if t not in self.skip]
        text = self.tok.decode(ids, skip_special_tokens=False)
        return any(stop in text for stop in self.strings)

    def visible(self, text: str, *, partial: bool = False) -> str:
        """The text before the first match; ``partial`` also holds back an end that may begin one (the Mac's rule)."""

        return StopPolicy.visible(self, text, partial=partial)


def hide_tool_calls(text: str, *, finished: bool) -> str:
    out: list[str] = []
    pos = 0
    while True:
        start = text.find(_CALL_OPEN, pos)
        if start < 0:
            tail = text[pos:]
            out.append(tail[: len(tail) - (0 if finished else _partial_tag(tail, _CALL_OPEN))])
            return "".join(out)
        if not _call_head(text, start + len(_CALL_OPEN)):          # a mentioned tag: text
            out.append(text[pos:start + len(_CALL_OPEN)])
            pos = start + len(_CALL_OPEN)
            continue
        out.append(text[pos:start])
        end = text.find(_CALL_CLOSE, start)
        if end < 0:
            return "".join(out)
        pos = end + len(_CALL_CLOSE)


def _tool_name(tool: dict[str, Any]) -> str:
    fn = tool.get("function") if isinstance(tool, dict) else None
    return str((fn or tool).get("name") or "").strip() if isinstance(tool, dict) else ""


def parse_tool_calls(text: str, tools: list[dict[str, Any]], *, max_calls: int | None = None,
                     rejected: list[str] | None = None) -> tuple[str, list[dict[str, Any]] | None]:
    """Qwen ``<function=name><parameter=k>v</parameter></function>``, GLM ``name<arg_key>..`` or JSON calls.
    ``rejected``, when given, gets the name of each call to a tool the request did not offer (#103): that block
    stays text, as before and as TensorFold's server since 7be90a36b, and is never a call."""

    if not tools:
        return text, None
    known = {_tool_name(t).lower(): _tool_name(t) for t in tools}
    schemas = parameter_schemas(tools)
    calls: list[dict[str, Any]] = []
    residue: list[str] = []
    cursor = 0
    for match in _call_blocks(text):
        residue.append(text[cursor:match.start()])
        cursor = match.end()
        if max_calls is not None and len(calls) >= max_calls:
            continue
        block = match.group(1).strip()
        name, args = None, {}
        try:
            payload = json.loads(block)
            if isinstance(payload, dict):
                fn = payload.get("function") if isinstance(payload.get("function"), dict) else payload
                name = fn.get("name")
                args = fn.get("arguments", fn.get("parameters", {}))
                if isinstance(args, str):
                    args = json.loads(args) if args.strip() else {}
        except (json.JSONDecodeError, AttributeError):
            m = _TOOL_FUNCTION_BLOCK_RE.match(block)
            if m:
                if max_calls is not None and _TOOL_PARAMETER_BLOCK_RE.sub("", m.group(2)).strip():
                    continue
                name = m.group(1).strip()
                # typed parameters (array, object, number...) decode per the tool's schema, as the Mac server does
                props = schemas.get(name.lower(), {})
                args = {key: decode_parameter(value, props.get(key, {}))
                        for key, value in ((p.group(1).strip(), p.group(2))
                                           for p in _TOOL_PARAMETER_BLOCK_RE.finditer(m.group(2)))}
            else:
                glm = parse_glm_tool_call_block(repair_glm_keys(block), tools, complete=max_calls is not None)
                if glm is not None:
                    name, args = glm
        if not name or str(name).lower() not in known:
            if name and rejected is not None:
                rejected.append(str(name)[:128])
            if max_calls is None:
                residue.append(match.group(0))
            continue
        if max_calls is not None:
            try:
                if not isinstance(args, dict):
                    continue
                json.dumps(args, allow_nan=False)
            except (ValueError, TypeError):
                continue
        calls.append({"id": f"call_{uuid.uuid4().hex[:24]}", "type": "function",
                      "function": {"name": known[str(name).lower()],
                                   "arguments": json.dumps(args, ensure_ascii=False, separators=(",", ":"))}})
    residue.append(text[cursor:])
    return "".join(residue).strip(), calls or None


_THINK_CLOSE = "</think>"
# a call written in the think block ends before its </think>: a tag the reasoning mentions, then the real call after
# the block closes, are not one block (and a mention opens none: ``_call_head``)
_CALL_BLOCK = re.compile(r"<tool_call>(?:(?!</think>).)*?</tool_call>", re.DOTALL)
THINK_CALL_HOLD = 1024      # characters of a call written inside the think block held before it streams as a call
_GLM_TAG = re.compile(r"</?arg_(?:key|value)>")
_LAST_WORD = re.compile(r"(\S+)\s*$")


def repair_glm_keys(block: str) -> str:
    """A GLM call whose ``<arg_key>`` the model left out, writing whitespace where that token belongs (issue #22:
    ``read path</arg_key><arg_value>..``, or ``</arg_value>\npath</arg_key>``), with it put back: the word before an
    unopened ``</arg_key>`` is its key. A block where nothing is missing comes back as it is."""

    if block.count(_KEY_END) <= block.count(_KEY):
        return block
    out, at, prev, prev_end = [], 0, None, 0     # prev: the last tag seen (ending at prev_end); at: text copied
    for tag in _GLM_TAG.finditer(block):
        if tag.group(0) == _KEY_END and prev in (None, _VALUE_END):
            seg_start = 0 if prev is None else prev_end
            word = _LAST_WORD.search(block, seg_start, tag.start())
            # the name's segment keeps a name before the key (``read path``): no word, or no name, is not repaired
            if word is None or (prev is None and not block[seg_start:word.start()].strip()):
                return block
            out += [block[at:word.start()], _KEY]
            at = word.start()
        prev, prev_end = tag.group(0), tag.end()
    return "".join(out) + block[at:]


def close_glm_call(text: str, tools: list[dict[str, Any]]) -> str:
    """What closes the GLM call a reply ended inside when it parses as a whole call to an offered tool (issue #22:
    the model wrote its end token before ``</tool_call>``): ``</tool_call>``, after ``</arg_value>`` when a value is
    open; "" when the reply is not inside a call, or the closed call would not parse (its markup is then text)."""

    at = text.rfind(_CALL_OPEN)
    if at < 0:
        return ""
    block = text[at + len(_CALL_OPEN):]
    if _CALL_CLOSE in block or _THINK_CLOSE in block:
        return ""
    suffix = (_VALUE_END if block.rfind(_VALUE) > block.rfind(_VALUE_END) else "") + _CALL_CLOSE
    # the strict reading (one whole call, nothing but its markup, arguments a JSON object)
    return suffix if parse_tool_calls(_CALL_OPEN + block + suffix, tools, max_calls=1)[1] else ""


def _call_run(text: str, start: int, finished: bool) -> tuple[int, str]:
    """(where the run of complete ``<tool_call>`` blocks from ``start`` ends, what it is): ``"calls"`` when the reply
    ended on it (nothing after it but whitespace and a closing ``</think>``), ``"pending"`` while that may still
    come true, ``"reasoning"`` once text follows it (more reasoning, or an answer after the think block)."""

    end = pos = start
    while (block := _CALL_BLOCK.match(text, pos)) is not None and _call_head(text, pos + len(_CALL_OPEN)):
        end = block.end()
        pos = len(text) - len(text[end:].lstrip())
    after = text[end:].lstrip()
    if after.startswith(_THINK_CLOSE) and not after[len(_THINK_CLOSE):].strip():
        after = ""
    if not after:
        return end, "calls" if finished and end > start else "pending"
    if after.startswith(_CALL_OPEN) and (not _call_head(after, len(_CALL_OPEN)) or _THINK_CLOSE in after):
        return end, "reasoning"                 # a mentioned tag, or a block the think block's close cuts
    if not finished and (after.startswith(_CALL_OPEN) or _CALL_OPEN.startswith(after)
                         or _THINK_CLOSE.startswith(after)):
        return end, "pending"                   # a block, or the think block's close, being written
    return end, "reasoning"


# patch 0117 (TF_GLM_REPLY_IDS): GLM's reply markup, which its tokenizer holds as single tokens
GLM_MARKERS = ("<think>", "</think>", "<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>",
               "</arg_value>")
_INERT = chr(0xE000)            # a spelled marker's last character while the parsers read it (the same length)
_INERT_JSON = chr(92) + "ue000"  # that character as json.dumps(ensure_ascii=True) writes it


class ReplyMarks:
    """TF_GLM_REPLY_IDS (patch 0117, on unless 0): GLM's reply markup is markup only where the reply's own marker
    tokens wrote it. ``</think>``, ``<tool_call>`` and the argument tags are single tokens; the same text spelled in
    ordinary tokens (a quoted tag, an example call, an echoed document) is words. ``reply()`` follows one reply;
    its ``mask`` makes those spellings inert at the same length, so the text parsers (the think split, the call
    hiding and streaming, the end parser, the closing of a cut call) keep their offsets and skip them, and
    ``unmask`` gives them back in what is sent. Patch 0122 is the request's side of the same rule."""

    def __init__(self, tok: Any, markers: tuple[str, ...] = GLM_MARKERS) -> None:
        self.tok = tok
        self.ids: dict[int, str] = {}
        for mark in markers:
            token = tok.token_to_id(mark)
            if token is not None and tok.decode([token], skip_special_tokens=False) == mark:
                self.ids[token] = mark
        self.inert = {mark: mark[:-1] + _INERT for mark in self.ids.values()}

    @classmethod
    def from_env(cls, tok: Any) -> "ReplyMarks | None":
        value = os.environ.get("TF_GLM_REPLY_IDS", "1").strip() or "1"
        if value not in ("0", "1"):
            raise ValueError(f"TF_GLM_REPLY_IDS={value!r}: expected 0 or 1")
        if value == "0":
            return None
        marks = cls(tok)
        print(f"[tensorfold] reply markup is read at its {len(marks.ids)} marker tokens; the same text spelled in "
              f"ordinary tokens stays words (TF_GLM_REPLY_IDS=0 turns it off)", flush=True)
        return marks

    def reply(self) -> "_ReplyMarks":
        return _ReplyMarks(self)

    def unmask(self, value: Any) -> Any:
        """``value`` (text, or the lists and dicts of a delta or a reply) with every inert marker given back."""

        if isinstance(value, str):
            if _INERT not in value and _INERT_JSON not in value:
                return value
            for mark, inert in self.inert.items():
                value = value.replace(inert, mark).replace(mark[:-1] + _INERT_JSON, mark)
            return value
        if isinstance(value, list):
            return [self.unmask(v) for v in value]
        if isinstance(value, tuple):
            return tuple(self.unmask(v) for v in value)
        if isinstance(value, dict):
            return {k: self.unmask(v) for k, v in value.items()}
        return value


class _ReplyMarks:
    """One reply's real markers: for each marker's text, which of its occurrences the reply's marker tokens wrote
    (the occurrences of that text in the decode before each such token), read as the tokens arrive."""

    def __init__(self, marks: ReplyMarks) -> None:
        self.marks = marks
        self.real: dict[str, set[int]] = {mark: set() for mark in marks.ids.values()}
        self.seen = 0

    def mask(self, text: str, tokens: list[int]) -> str:
        ids = self.marks.ids
        for at in range(self.seen, len(tokens)):
            mark = ids.get(tokens[at])
            if mark is not None:
                self.real[mark].add(self.marks.tok.decode(tokens[:at], skip_special_tokens=False).count(mark))
        self.seen = len(tokens)
        cuts = []
        for mark, real in self.real.items():
            at, n = text.find(mark), 0
            while at >= 0:
                if n not in real:
                    cuts.append((at, mark))
                n += 1
                at = text.find(mark, at + len(mark))
        if not cuts:
            return text
        out, done = [], 0
        for at, mark in sorted(cuts):
            out += [text[done:at], self.marks.inert[mark]]
            done = at + len(mark)
        out.append(text[done:])
        return "".join(out)


class ThinkSplit:
    """(reasoning, answer) of a thinking GLM reply with tools, streamed or whole: the think block ends at its
    ``</think>``, and calls the model wrote inside it are its calls only when they end the reply (nothing after them
    but whitespace and the block's close; theirs is the D5 rule of jayleaton/glm53-tensorfold-spark patch 0620, and
    upstream's split read any call in an unclosed block as the answer). A call in the think block is held: its text
    stays out of the reasoning until the reply ends on it (a call) or text follows it (reasoning after all). With
    ``hold``, a held call longer than ``hold`` characters is taken as a call at once (``committed``) so a long file
    write streams while it is written; nothing after it can make it reasoning again.

    ``stream_from`` is where the text a call streamer reads begins once known (the answer, or a committed call); a
    reply whose calls it never reaches has them from the end parser."""

    def __init__(self, hold: int | None = None) -> None:
        self.hold = hold
        self.floor = 0                  # calls before this are reasoning
        self.committed: int | None = None
        self.stream_from: int | None = None

    def __call__(self, text: str, finished: bool) -> tuple[str, str]:
        if self.committed is not None:
            at = self.committed
            return text[:at], text[at:].replace(_THINK_CLOSE, "", 1).lstrip()
        close = text.find(_THINK_CLOSE)
        while True:
            call = text.find(_CALL_OPEN, self.floor)
            if close >= 0 and (call < 0 or close < call):
                self.stream_from = close + len(_THINK_CLOSE)
                return text[:close], text[self.stream_from:].lstrip("\n")
            if call < 0:
                held = 0 if finished else max(_partial_tag(text, tag) for tag in (_THINK_CLOSE, _CALL_OPEN))
                return text[:len(text) - held], ""
            end, kind = _call_run(text, call, finished)
            if kind == "calls":
                return text[:call], text[call:end]
            if kind == "reasoning":
                self.floor = max(end, call + len(_CALL_OPEN))
                continue
            if self.hold is not None and len(text) - call > self.hold and close < 0:
                self.committed = self.stream_from = call
                return self(text, finished)
            return text[:call], ""


_KEY, _KEY_END, _VALUE, _VALUE_END = "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"
_VALUE_OPENS = re.compile(r"\s*<arg_value>")


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _same_object(text: str, other: str) -> bool:
    """Whether two JSON texts decode to the same object, key order and value types included (a repeated key: its last
    value in its first key's place, as ``json.loads`` and the end parser's dict both read it)."""

    def shape(value: Any) -> Any:
        if isinstance(value, dict):
            return ["object", [(k, shape(v)) for k, v in value.items()]]
        if isinstance(value, list):
            return ["array", [shape(v) for v in value]]
        return [type(value).__name__, value]

    try:
        return shape(json.loads(text)) == shape(json.loads(other))
    except ValueError:
        return False


class GlmCallStreamer:
    """GLM's ``<tool_call>NAME<arg_key>K</arg_key><arg_value>V</arg_value>...</tool_call>`` calls as OpenAI tool-call
    deltas while they are written (patch 0131; with 0053 each call went out whole at its ``</tool_call>``, so a long
    file write sent no event for minutes and an agent client's token count stopped). A call's header (index, id, name,
    empty arguments) goes out once its name is whole and names an offered tool; then its arguments' JSON in pieces: a
    text value as JSON-escaped pieces while it decodes (a tail that may begin ``</arg_value>`` or ``</tool_call>``
    waits; the stream decoder already holds back a partial character), a typed or nullable value whole at its
    ``</arg_value>``, as ``decode_parameter`` reads it. The closing brace waits for the block's ``</tool_call>``: the
    end parser then reads the block, and the call goes on from what went out to the parser's arguments (normally just
    the brace), so the pieces join to ``parse_tool_calls``'s arguments byte for byte, key order, escaping, typing and
    unknown keys included. Where the streamer cannot tell how the parser will read a call (an ``<arg_key>`` the model
    left out, which the parser puts back; text after an ``</arg_key>``, which can lengthen the key) it holds that call's
    pieces and the parser's arguments go out at the closer. A repeated key goes out twice (the parser keeps one value
    in the first key's place); the call closes when its JSON decodes to the parser's object, which ``json.loads`` gives.
    A call whose sent pieces the parser does not continue (a value the block's closer cuts) gets no closing brace: it
    stays open, and the server logs a line. A call the reply ends inside (its token limit, a stop string) stays open
    too, as vLLM and the Anthropic API stream a cut call: no JSON goes out as complete that the parser would not return.

    ``feed`` takes the reply's answer so far (text that only grows; a text that does not extend the one read turns the
    streamer off for the reply) and returns the new deltas. ``calls`` holds each call whose header went out (its
    arguments as sent, with ``unmask`` not applied), ``whole()`` the ones sent closed, ``sent`` their count. A block it
    cannot follow (not GLM's markup, a tool the request did not offer) is skipped and stays with the end parser
    (``rest``). ``unmask`` (patch 0117) gives a call's arguments back their spelled markup: it runs on all of a call's
    arguments, so a spelled tag split between two pieces is given back whole."""

    def __init__(self, tools: list[dict[str, Any]], unmask: Any = None) -> None:
        self.tools = tools
        self.known = {_tool_name(t).lower(): _tool_name(t) for t in tools}
        self.schemas = parameter_schemas(tools)
        self.unmask = unmask if unmask is not None else (lambda value: value)
        self.calls: list[dict[str, Any]] = []          # every call whose header went out, its arguments as sent
        self.status: list[str] = []                     # each call: "open", "whole" (sent closed), "left" (left open)
        self.shown: list[str] = []                      # each call's arguments as the deltas wrote them (unmasked)
        self.announced = 0                              # headers sent
        self.flushed = 0                                # calls before this one have every piece sent
        self.skipped: list[str] = []                    # whole blocks it did not follow, for the end parser
        self.pos, self.state, self.start = 0, "outside", 0
        self.end = -1                                   # the current block's </tool_call>, once written
        self.scan = 0                                   # where the search for that closer goes on
        self.open = False                               # the last call's header went out, its </tool_call> has not
        self.schema: dict[str, Any] = {}               # the current call's parameter schemas
        self.value_schema: dict[str, Any] | None = None     # the current typed value's schema, None for text
        self.maybe_null = False                         # a nullable text value that may still be ``null``: held
        self.head = ""                                  # the current argument's JSON head, sent with its value
        self.keys: set[str] = set()                     # the current call's keys
        self.repeated = False                           # the current call repeated a key
        self.read = ""                                  # the text read so far
        self.off = False                                # the text changed under the streamer: nothing more streams
        self.sent = 0                                   # calls sent whole

    def feed(self, text: str, block: bool = False) -> list[dict[str, Any]]:
        """The new deltas in ``text``; ``block``: only to the end of the call being written (its </tool_call>), so the
        server sends its last pieces before the text that follows its block."""

        if self.off:
            return []
        if not text.startswith(self.read):              # positions hold only on a text that extends the one read
            self.off = True
            print(f"[tensorfold] GLM tool-call stream off for this reply: its text changed under the streamer "
                  f"({len(self.calls)} call headers sent; the end parser sends the rest)", flush=True)
            return []
        self.read = text
        self._follow(text, block and self.open)
        return self._deltas()

    def whole(self) -> list[dict[str, Any]]:
        """The calls sent closed, in order (their arguments are the end parser's)."""

        return [call for call, status in zip(self.calls, self.status) if status == "whole"]

    def _deltas(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for index in range(self.flushed, len(self.calls)):
            call = self.calls[index]
            if index >= self.announced:
                out.append({"tool_calls": [{"index": index, "id": call["id"], "type": "function",
                                            "function": {"name": call["function"]["name"], "arguments": ""}}]})
                self.announced = index + 1
            shown = self.unmask(call["function"]["arguments"])
            if len(shown) > len(self.shown[index]):
                if not shown.startswith(self.shown[index]):         # never: an unmasked text that is not an extension
                    self._leave(index, "its unmasked arguments changed")
                    continue
                piece = shown[len(self.shown[index]):]
                out.append({"tool_calls": [{"index": index, "function": {"arguments": piece}}]})
                self.shown[index] = shown
        self.flushed = len(self.calls) - (1 if self.open else 0)
        return out

    def _follow(self, text: str, block: bool = False) -> None:
        while True:
            if self.state == "outside":
                if block:
                    return
                at = text.find(_CALL_OPEN, self.pos)
                if at < 0:
                    return
                self.start, self.end = at, -1
                self.pos = self.scan = at + len(_CALL_OPEN)
                self.state = "name"
                continue
            if self.end < 0:                            # the end parser's block ends at the first </tool_call>
                found = text.find(_CALL_CLOSE, self.scan)
                if found >= 0:
                    self.end = found
                else:
                    self.scan = max(self.scan, len(text) - len(_CALL_CLOSE) + 1)
            whole = self.end >= 0                       # the block is written: nothing more comes inside it
            view = text[:self.end] if whole else text
            body = self.start + len(_CALL_OPEN)
            if self.state == "skip":                    # a block the end parser decides: to its end
                if not whole:
                    return
                self.skipped.append(text[self.start:self.end + len(_CALL_CLOSE)])
                self._next()
                continue
            if self.state == "name":                    # the end parser's name: the text before <arg_key> or the end
                if not _call_head(text, body):          # a mentioned tag: text, as the end parser reads it
                    self.state, self.pos = "outside", body
                    continue
                key = view.find(_KEY, body)
                stop = key if key >= 0 else (self.end if whole else -1)
                if stop < 0:
                    if len(view) - body > 256:
                        self.state = "skip"
                        continue
                    return
                name = view[body:stop].strip()
                if not self._callable(name):
                    self.state = "skip"
                    continue
                self._header(self.known[name.lower()])
                self.pos, self.state = stop, "arguments"
            self._arguments(view, whole)
            if not whole:
                return
            self._close(text[self.start:self.end + len(_CALL_CLOSE)])
            self._next()

    def _arguments(self, view: str, whole: bool) -> None:
        """Follow the current call's arguments in ``view`` (its block so far, all of it when ``whole``), as
        ``_GLM_ARG_RE``'s findall reads them: each ``<arg_key>K</arg_key>`` then ``<arg_value>V</arg_value>``, text
        between arguments skipped."""

        while True:
            if self.state == "held":                    # the end parser decides the rest of this call at its closer
                return
            if self.state == "arguments":
                key = view.find(_KEY, self.pos)
                if _KEY_END in view[self.pos:key if key >= 0 else len(view)]:
                    self.state = "held"                 # an <arg_key> the model left out (#22): the parser puts it back
                    return
                if key < 0:
                    return
                self.pos, self.state = key + len(_KEY), "key"
            elif self.state == "key":
                end = view.find(_KEY_END, self.pos)
                if end < 0:                             # being written, or the block ends in it (then no argument)
                    return
                opens = _VALUE_OPENS.match(view, end + len(_KEY_END))
                if opens is None:
                    after = view[end + len(_KEY_END):]
                    if not whole and (not after.strip() or _VALUE.startswith(after.lstrip())):
                        return                          # its value's opener is being written
                    self.state = "held"                 # the parser may read a longer key, to a later </arg_key>
                    return
                key = view[self.pos:end].strip()
                schema = self.schema.get(key, {})
                self.value_schema = schema if typed_parameter(schema) else None
                self.maybe_null = self.value_schema is None and nullable_text(schema)
                self.repeated = self.repeated or key in self.keys
                self.keys.add(key)
                opened = "," if self.calls[-1]["function"]["arguments"] else "{"
                quote = "" if self.value_schema is not None or self.maybe_null else '"'
                self.head = opened + _json(key) + ":" + quote
                self.pos, self.state = opens.end(), "value"
            elif self.state == "value":
                end = view.find(_VALUE_END, self.pos)
                if end < 0 and whole:                   # the block ends inside the value: no such argument
                    self.state = "held"
                    return
                if self.value_schema is not None:       # typed: decoded whole, as the end parser does
                    if end < 0:
                        return
                    self._args(self.head + _json(decode_parameter(view[self.pos:end], self.value_schema,
                                                                  python=False)))
                elif self.maybe_null:                   # text or null: held while it may still be ``null``
                    written = view[self.pos:end] if end >= 0 else self._ready(view)
                    if end >= 0 and written == "null":
                        self._args(self.head + "null")
                    elif end < 0 and "null".startswith(written):
                        return
                    else:
                        self.head += '"'
                        self.maybe_null = False
                        continue
                else:                                   # text: as it arrives, less a tail that may begin a closer
                    written = view[self.pos:end] if end >= 0 else self._ready(view)
                    piece = _json(written)[1:-1] + ('"' if end >= 0 else "")
                    if piece:
                        self._args(self.head + piece)
                        self.head = ""
                    if end < 0:
                        self.pos += len(written)
                        return
                self.pos, self.state, self.head = end + len(_VALUE_END), "arguments", ""

    def _ready(self, view: str) -> str:
        """The value text from ``pos`` that can go out: less a tail that may begin ``</arg_value>`` or
        ``</tool_call>``."""

        held = max(_partial_tag(view, _VALUE_END), _partial_tag(view, _CALL_CLOSE))
        return view[self.pos:max(self.pos, len(view) - held)]

    def _args(self, piece: str) -> None:
        self.calls[-1]["function"]["arguments"] += piece

    def _header(self, name: str) -> None:
        self.calls.append({"id": f"call_{uuid.uuid4().hex[:24]}", "type": "function",
                           "function": {"name": name, "arguments": ""}})
        self.status.append("open")
        self.shown.append("")
        self.open = True
        self.schema = self.schemas.get(name.lower(), {})
        self.value_schema, self.maybe_null, self.head = None, False, ""
        self.keys, self.repeated = set(), False

    def _close(self, block: str) -> None:
        """The current call's block is whole: the end parser reads it, and the call goes on to the parser's arguments
        when they continue what went out; else it is left open (no brace closes JSON the parser does not return)."""

        if not self.open:                               # a mention, or a block skipped: nothing was sent
            return
        index = len(self.calls) - 1
        call, self.open = self.calls[index], False
        sent = call["function"]["arguments"]
        parsed = parse_tool_calls(block, self.tools)[1] or []
        args = (parsed[0]["function"]["arguments"] if len(parsed) == 1
                and parsed[0]["function"]["name"] == call["function"]["name"] else None)
        if args is not None and args.startswith(sent):
            call["function"]["arguments"] = args
        elif args is not None and self.repeated and _same_object(sent + "}", args):
            call["function"]["arguments"] = sent + "}"          # a repeated key: the same object as the parser's
        else:
            self._leave(index, "the end parser reads its block otherwise" if args is not None
                        else "the end parser takes no call from its block")
            return
        self.status[index] = "whole"
        self.sent += 1

    def _leave(self, index: int, why: str) -> None:
        if self.status[index] != "left":
            print(f"[tensorfold] GLM tool call {index} ({self.calls[index]['function']['name']}) left open: {why}; "
                  f"no closing brace was sent", flush=True)
        self.status[index] = "left"

    def _next(self) -> None:
        self.pos, self.state, self.end = self.end + len(_CALL_CLOSE), "outside", -1

    def _callable(self, name: str) -> bool:
        """Whether the end parser reads a block beginning ``name`` as a GLM call to an offered tool."""

        if _GLM_NAME.fullmatch(name) is None or name.lower() not in self.known:
            return False
        try:
            json.loads(name)                            # a name that is JSON (``true``, ``1``) is read as JSON
        except ValueError:
            return True
        return False

    def rest(self, tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """The calls the end parser reads in the blocks this streamer skipped (JSON or Qwen markup): sent at the end."""

        return [call for block in self.skipped for call in parse_tool_calls(block, tools)[1] or []]


# -- chat template -------------------------------------------------------------------------
