//------------------------------------------------------------------------
// auxVST common — base64 encoder (CNXB viz transport)
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//------------------------------------------------------------------------

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace auxvst {

inline void encodeBase64 (const void* data, size_t len, std::string& out)
{
	static const char* tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const auto* bytes = static_cast<const uint8_t*> (data);
	out.clear ();
	out.reserve (((len + 2) / 3) * 4);
	size_t i = 0;
	for (; i + 2 < len; i += 3)
	{
		uint32_t n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
		out += tbl[(n >> 18) & 63];
		out += tbl[(n >> 12) & 63];
		out += tbl[(n >> 6) & 63];
		out += tbl[n & 63];
	}
	if (i < len)
	{
		uint32_t n = bytes[i] << 16;
		if (i + 1 < len)
			n |= bytes[i + 1] << 8;
		out += tbl[(n >> 18) & 63];
		out += tbl[(n >> 12) & 63];
		out += (i + 1 < len) ? tbl[(n >> 6) & 63] : '=';
		out += '=';
	}
}

} // namespace auxvst
