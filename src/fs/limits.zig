pub const max_read: usize = 1024 * 1024;
pub const max_write: usize = 1024 * 1024;
pub const max_upload: usize = 64 * 1024 * 1024;

/// 单次 list 最多返回的条目数；超出时截断并标记 `truncated`。
pub const max_list_entries: usize = 10_000;
/// 目录归档的条目/字节上限；超出时停止追加并写入说明文件。
pub const max_tar_entries: usize = 50_000;
pub const max_tar_bytes: u64 = 8 * 1024 * 1024 * 1024;
