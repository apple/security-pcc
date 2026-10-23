// Copyright © 2026 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

#pragma once
#include <cstdint>
#include <optional>
#include <string_view>

namespace llmsim
{
struct JsonObject;
struct JsonArray;
struct JsonValue {
	enum Kind : uint8_t { String, Number, Integer, True, False, Null, Object, Array, Unknown } m_kind;

	union {
		int64_t m_integer;
		double m_number;
		std::string_view m_str;
		JsonObject * m_object;
		JsonArray * m_array;
	};

	explicit JsonValue(Kind kind) : m_kind(kind)
	{
	}

	[[nodiscard]] bool
	is_integer() const
	{
		return m_kind == Integer;
	}
	[[nodiscard]] bool
	is_number() const
	{
		return m_kind == Number;
	}
	[[nodiscard]] bool
	is_string() const
	{
		return m_kind == String;
	}
	[[nodiscard]] bool
	is_object() const
	{
		return m_kind == Object;
	}
	[[nodiscard]] bool
	is_array() const
	{
		return m_kind == Array;
	}
	[[nodiscard]] bool
	is_boolean() const
	{
		return m_kind == True || m_kind == False;
	}
	[[nodiscard]] bool is_null() const;

	[[nodiscard]] std::string_view string() const;
	[[nodiscard]] double number() const;
	[[nodiscard]] int64_t integer() const;
	[[nodiscard]] bool boolean() const;

	// Object operations
	[[nodiscard]] bool has_key(std::string_view key) const;
	JsonValue const & operator[](std::string_view key) const;

	// Array operations
	[[nodiscard]] size_t length() const;
	JsonValue const & operator[](size_t index) const;
};

class Arena
{
	constexpr static size_t kCapacity = 1 << 30; // 1GB
	size_t m_allocated                = 0;       // number of bytes used so far.
	uint8_t * m_memory;

  public:
	[[nodiscard]] void * allocate(size_t bytes, size_t alignment = alignof(std::max_align_t));
	~Arena();
	Arena();
	Arena(Arena && other) noexcept;
	Arena & operator=(Arena && other) noexcept;
	void reset();
};

template <typename T, typename... Args>
T *
arena_new(Arena & arena, Args &&... args)
{
	void * mem = arena.allocate(sizeof(T), alignof(T));
	if (!mem) {
		return nullptr;
	}
	return new (mem) T(std::forward<Args>(args)...);
}

class Json
{
	const char * m_data;
	JsonValue m_root;
	Arena m_arena;
	Json(const char * str);

  public:
	~Json()
	{
		if (m_data) {
			::free((void *)m_data);
		}
	}

	Json(Json const &)             = delete;
	Json & operator=(Json const &) = delete;

	Json(Json && other) noexcept : m_data(other.m_data), m_root(other.m_root), m_arena(std::move(other.m_arena))
	{
		other.m_data = nullptr;
	}

	Json &
	operator=(Json && other) noexcept
	{
		if (this != &other) {
			m_data       = other.m_data;
			m_root       = other.m_root;
			m_arena      = std::move(other.m_arena);
			other.m_data = nullptr;
		}

		return *this;
	}

	[[nodiscard]] std::string_view
	string() const
	{
		return m_root.string();
	}
	[[nodiscard]] bool
	is_number() const
	{
		return m_root.is_number();
	}
	[[nodiscard]] bool
	is_integer() const
	{
		return m_root.is_integer();
	}
	[[nodiscard]] bool
	is_string() const
	{
		return m_root.is_string();
	}
	[[nodiscard]] bool
	is_object() const
	{
		return m_root.is_object();
	}
	[[nodiscard]] bool
	is_array() const
	{
		return m_root.is_array();
	}
	[[nodiscard]] bool
	is_boolean() const
	{
		return m_root.is_boolean();
	}
	[[nodiscard]] bool
	is_null() const
	{
		return m_root.is_null();
	}

	[[nodiscard]] double
	number() const
	{
		return m_root.number();
	}
	[[nodiscard]] int64_t
	integer() const
	{
		return m_root.integer();
	}
	[[nodiscard]] bool
	boolean() const
	{
		return m_root.boolean();
	}

	// Object operations
	[[nodiscard]] bool
	has_key(std::string_view key) const
	{
		return m_root.has_key(key);
	}
	JsonValue const &
	operator[](std::string_view key) const
	{
		return m_root[key];
	}

	// Array operations
	[[nodiscard]] size_t
	length() const
	{
		return m_root.length();
	}
	JsonValue const &
	operator[](size_t index)
	{
		return m_root[index];
	}

	static std::optional<Json> parse(const char * str);
};

} // namespace llmsim
