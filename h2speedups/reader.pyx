# cython: language_level=3
from collections import deque

from libc.stdint cimport uint8_t, uint32_t

from hyperframe.frame import HeadersFrame, ExtensionFrame

cdef int HEADER_SIZE = 9;


cdef inline read_int24(char *buf, int offset):
    return <uint32_t>(
        <uint8_t>buf[offset + 0] << 16 |
        <uint8_t>buf[offset + 1] << 8  |
        <uint8_t>buf[offset + 2]
    )


cdef inline read_int32(char *buf, int offset):
    return <uint32_t>(
        <uint8_t>buf[offset + 0] << 24 |
        <uint8_t>buf[offset + 1] << 16 |
        <uint8_t>buf[offset + 2] << 8  |
        <uint8_t>buf[offset + 3]
    )


cdef inline read_frame_header(char *buf, int offset):
    cdef uint32_t length = read_int24(buf, offset)
    cdef uint8_t type_ = buf[offset + 3]
    cdef uint8_t flags = buf[offset + 4]
    cdef uint32_t stream_id = read_int32(buf, offset + 5) & 0x7FFFFFFF
    return length, type_, flags, stream_id


cdef inline read_padding(char *buf, int offset, frame):
    if frame.flags.PADDED:
        frame.pad_length = buf[offset]
        return offset + 1
    return offset


cdef inline read_priority(char *buf, int offset, frame):
    if frame.flags.PRIORITY:
        depends_on = read_int32(buf, offset)
        frame.stream_weight = buf[offset + 4]
        frame.exclusive = True if depends_on >> 31 else False
        frame.depends_on = depends_on & 0x7FFFFFFF
        return offset + 5
    return offset


cdef read_headers_frame(char *buf, int offset, int length, frame):
    offset = read_padding(buf, offset, frame)
    offset = read_priority(buf, offset, frame)
    frame.data = buf[offset:offset + length - frame.pad_length]
    frame.body_len = length


cdef dispatch(
    char *buf,
    int offset,
    int length,
    int type_,
    int flags,
    int stream_id,
):
    if type_ == HeadersFrame.type:
        frame = HeadersFrame(stream_id)
        frame.parse_flags(flags)
        read_headers_frame(buf, offset, length, frame)
        return frame
    else:
        return ExtensionFrame(type_, stream_id)


cdef class Reader:
    cdef bytearray _head
    cdef object _tail

    def __init__(self):
        self._head = bytearray()
        self._tail = deque()

    def feed(self, bytes data):
        if not self._head:
            assert not self._tail
            self._head += data
        else:
            self._tail.append(data)

        frames = []
        offset = 0
        while True:
            while len(self._head) < HEADER_SIZE and self._tail:
                self._head += self._tail.popleft()
            if len(self._head) < HEADER_SIZE:
                break

            length, type_, flags, stream_id = read_frame_header(
                self._head, offset,
            )

            if length > 0:
                while len(self._head) < HEADER_SIZE + length and self._tail:
                    self._head += self._tail.popleft()
                if len(self._head) < HEADER_SIZE + length:
                    break

            frames.append(dispatch(
                self._head,
                offset + HEADER_SIZE,
                length,
                type_,
                flags,
                stream_id,
            ))

            offset += HEADER_SIZE + length
            if len(self._head) == offset:
                self._head.clear()
                offset = 0

        if offset > 0:
            del self._head[:offset]
        return frames
