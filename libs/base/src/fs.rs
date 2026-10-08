#[cfg(windows)]
use std::os::windows::prelude::*;
use std::{
    collections::HashMap,
    convert::TryFrom,
    fmt::{Debug, Display},
    io::{self, Cursor},
    path::{Path, PathBuf},
    sync::atomic::{AtomicI32, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_derive::{Deserialize, Serialize};
use serde_json::json;
use tokio::{
    fs::File,
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufStream as TokioBufStream},
    task::JoinHandle,
};

use crate::message_proto::*;
// https://doc.rust-lang.org/std/os/windows/fs/trait.MetadataExt.html
use hbb_common::{
    anyhow::anyhow,
    bail,
    compress::{compress, decompress},
    config::Config,
    get_version_number,
    sha2::{Digest as ShaDigest, Sha256},
    ResultType, Stream,
};

static NEXT_JOB_ID: AtomicI32 = AtomicI32::new(1);

pub fn get_next_job_id() -> i32 {
    NEXT_JOB_ID.fetch_add(1, Ordering::SeqCst)
}

pub fn update_next_job_id(id: i32) {
    NEXT_JOB_ID.store(id, Ordering::SeqCst);
}

pub fn read_dir(path: &Path, include_hidden: bool) -> ResultType<FileDirectory> {
    let mut dir = FileDirectory {
        path: get_string(path),
        ..Default::default()
    };
    #[cfg(windows)]
    if "/" == &get_string(path) {
        let drives = unsafe { winapi::um::fileapi::GetLogicalDrives() };
        for i in 0..32 {
            if drives & (1 << i) != 0 {
                let name = format!(
                    "{}:",
                    std::char::from_u32('A' as u32 + i as u32).unwrap_or('A')
                );
                dir.entries.push(FileEntry {
                    name,
                    entry_type: FileType::DirDrive.into(),
                    ..Default::default()
                });
            }
        }
        return Ok(dir);
    }
    for entry in path.read_dir()?.flatten() {
        let p = entry.path();
        let name = p
            .file_name()
            .map(|p| p.to_str().unwrap_or(""))
            .unwrap_or("")
            .to_owned();
        if name.is_empty() {
            continue;
        }
        let mut is_hidden = false;
        let meta;
        if let Ok(tmp) = std::fs::symlink_metadata(&p) {
            meta = tmp;
        } else {
            continue;
        }
        // docs.microsoft.com/en-us/windows/win32/fileio/file-attribute-constants
        #[cfg(windows)]
        if meta.file_attributes() & 0x2 != 0 {
            is_hidden = true;
        }
        #[cfg(not(windows))]
        if name.find('.').unwrap_or(usize::MAX) == 0 {
            is_hidden = true;
        }
        if is_hidden && !include_hidden {
            continue;
        }
        let (entry_type, size) = {
            if p.is_dir() {
                if meta.file_type().is_symlink() {
                    (FileType::DirLink.into(), 0)
                } else {
                    (FileType::Dir.into(), 0)
                }
            } else if meta.file_type().is_symlink() {
                (FileType::FileLink.into(), 0)
            } else {
                (FileType::File.into(), meta.len())
            }
        };
        let modified_time = meta
            .modified()
            .map(|x| {
                x.duration_since(std::time::SystemTime::UNIX_EPOCH)
                    .map(|x| x.as_secs())
                    .unwrap_or(0)
            })
            .unwrap_or(0);
        dir.entries.push(FileEntry {
            name: get_file_name(&p),
            entry_type,
            is_hidden,
            size,
            modified_time,
            ..Default::default()
        });
    }
    Ok(dir)
}

#[inline]
pub fn get_file_name(p: &Path) -> String {
    p.file_name()
        .map(|p| p.to_str().unwrap_or(""))
        .unwrap_or("")
        .to_owned()
}

#[inline]
pub fn get_string(path: &Path) -> String {
    path.to_str().unwrap_or("").to_owned()
}

#[inline]
pub fn get_path(path: &str) -> PathBuf {
    Path::new(path).to_path_buf()
}

#[inline]
pub fn get_home_as_string() -> String {
    get_string(&Config::get_home())
}

fn read_dir_recursive(
    path: &Path,
    prefix: &Path,
    include_hidden: bool,
) -> ResultType<Vec<FileEntry>> {
    let mut files = Vec::new();
    if path.is_dir() {
        // to-do: symbol link handling, cp the link rather than the content
        // to-do: file mode, for unix
        let fd = read_dir(path, include_hidden)?;
        for entry in fd.entries.iter() {
            match entry.entry_type.enum_value() {
                Ok(FileType::File) => {
                    let mut entry = entry.clone();
                    entry.name = get_string(&prefix.join(entry.name));
                    files.push(entry);
                }
                Ok(FileType::Dir) => {
                    if let Ok(mut tmp) = read_dir_recursive(
                        &path.join(&entry.name),
                        &prefix.join(&entry.name),
                        include_hidden,
                    ) {
                        for entry in tmp.drain(0..) {
                            files.push(entry);
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(files)
    } else if path.is_file() {
        let (size, modified_time) = if let Ok(meta) = std::fs::metadata(path) {
            (
                meta.len(),
                meta.modified()
                    .map(|x| {
                        x.duration_since(std::time::SystemTime::UNIX_EPOCH)
                            .map(|x| x.as_secs())
                            .unwrap_or(0)
                    })
                    .unwrap_or(0),
            )
        } else {
            (0, 0)
        };
        files.push(FileEntry {
            entry_type: FileType::File.into(),
            size,
            modified_time,
            ..Default::default()
        });
        Ok(files)
    } else {
        bail!("Not exists");
    }
}

pub fn get_recursive_files(path: &str, include_hidden: bool) -> ResultType<Vec<FileEntry>> {
    read_dir_recursive(&get_path(path), &get_path(""), include_hidden)
}

fn read_empty_dirs_recursive(
    path: &Path,
    prefix: &Path,
    include_hidden: bool,
) -> ResultType<Vec<FileDirectory>> {
    let mut dirs = Vec::new();
    if path.is_dir() {
        // to-do: symbol link handling, cp the link rather than the content
        // to-do: file mode, for unix
        let fd = read_dir(path, include_hidden)?;
        if fd.entries.is_empty() {
            dirs.push(fd);
        } else {
            for entry in fd.entries.iter() {
                match entry.entry_type.enum_value() {
                    Ok(FileType::Dir) => {
                        if let Ok(mut tmp) = read_empty_dirs_recursive(
                            &path.join(&entry.name),
                            &prefix.join(&entry.name),
                            include_hidden,
                        ) {
                            for entry in tmp.drain(0..) {
                                dirs.push(entry);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        Ok(dirs)
    } else if path.is_file() {
        Ok(dirs)
    } else {
        bail!("Not exists");
    }
}

pub fn get_empty_dirs_recursive(
    path: &str,
    include_hidden: bool,
) -> ResultType<Vec<FileDirectory>> {
    read_empty_dirs_recursive(&get_path(path), &get_path(""), include_hidden)
}

#[inline]
pub fn is_file_exists(file_path: &str) -> bool {
    return Path::new(file_path).exists();
}

#[inline]
pub fn can_enable_overwrite_detection(version: i64) -> bool {
    version >= get_version_number("1.1.10")
}

#[repr(i32)]
#[derive(Copy, Clone, Serialize, Debug, PartialEq)]
pub enum JobType {
    Generic = 0,
    Printer = 1,
}

impl Default for JobType {
    fn default() -> Self {
        JobType::Generic
    }
}

impl From<JobType> for file_transfer_send_request::FileType {
    fn from(t: JobType) -> Self {
        match t {
            JobType::Generic => file_transfer_send_request::FileType::Generic,
            JobType::Printer => file_transfer_send_request::FileType::Printer,
        }
    }
}

impl From<i32> for JobType {
    fn from(value: i32) -> Self {
        match value {
            0 => JobType::Generic,
            1 => JobType::Printer,
            _ => JobType::Generic,
        }
    }
}

impl Into<i32> for JobType {
    fn into(self) -> i32 {
        self as i32
    }
}

impl JobType {
    pub fn from_proto(t: ::protobuf::EnumOrUnknown<file_transfer_send_request::FileType>) -> Self {
        match t.enum_value() {
            Ok(file_transfer_send_request::FileType::Generic) => JobType::Generic,
            Ok(file_transfer_send_request::FileType::Printer) => JobType::Printer,
            _ => JobType::Generic,
        }
    }
}

#[derive(Debug)]
pub enum DataSource {
    FilePath(PathBuf),
    MemoryCursor(Cursor<Vec<u8>>),
}

impl Default for DataSource {
    fn default() -> Self {
        DataSource::FilePath(PathBuf::new())
    }
}

impl serde::Serialize for DataSource {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            DataSource::FilePath(p) => serializer.serialize_str(p.to_str().unwrap_or("")),
            DataSource::MemoryCursor(_) => serializer.serialize_str(""),
        }
    }
}

impl Display for DataSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataSource::FilePath(p) => write!(f, "File: {}", p.to_string_lossy().to_string()),
            DataSource::MemoryCursor(_) => write!(f, "Bytes"),
        }
    }
}

impl DataSource {
    fn to_meta(&self) -> String {
        match self {
            DataSource::FilePath(p) => p.to_string_lossy().to_string(),
            DataSource::MemoryCursor(_) => "".to_string(),
        }
    }
}

enum DataStream {
    FileStream(File),
    BufStream(TokioBufStream<Cursor<Vec<u8>>>),
}

impl Debug for DataStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataStream::FileStream(fs) => write!(f, "{:?}", fs),
            DataStream::BufStream(_) => write!(f, "BufStream"),
        }
    }
}

impl DataStream {
    async fn write_all(&mut self, buf: &[u8]) -> ResultType<()> {
        match self {
            DataStream::FileStream(fs) => fs.write_all(buf).await?,
            DataStream::BufStream(bs) => bs.write_all(buf).await?,
        }
        Ok(())
    }

    async fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            DataStream::FileStream(fs) => fs.read(buf).await,
            DataStream::BufStream(bs) => bs.read(buf).await,
        }
    }
}

const PARTIAL_OWNERSHIP_VERSION: u32 = 3;

#[derive(Default, Serialize, Deserialize, Debug, Clone)]
pub struct FileDigest {
    pub size: u64,
    pub modified: u64,
    #[serde(default)]
    pub content_sha256: Vec<u8>,
    /// Legacy marker retained only for backwards-compatible deserialization.
    /// It is never sufficient proof that the adjacent partial belongs to the
    /// current job.
    #[serde(default)]
    pub rustdesk_owned_partial: bool,
    #[serde(default)]
    ownership: Option<PartialFileOwnership>,
}

#[derive(Default, Serialize, Deserialize, Debug, Clone)]
struct PartialFileOwnership {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    token: String,
    #[serde(default)]
    creator_job_id: i32,
    #[serde(default)]
    remote: String,
    #[serde(default)]
    destination: String,
    #[serde(default)]
    file_num: i32,
    #[serde(default)]
    source_size: u64,
    #[serde(default)]
    source_modified: u64,
    #[serde(default)]
    source_sha256: Vec<u8>,
    #[serde(default)]
    partial_storage: u64,
    #[serde(default)]
    partial_file: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileIdentity {
    storage: u64,
    file: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SourceDigestSnapshot {
    file_num: i32,
    identity: FileIdentity,
    size: u64,
    modified: u64,
}

#[cfg(windows)]
fn file_identity(file: &std::fs::File) -> io::Result<FileIdentity> {
    let mut info: winapi::um::fileapi::BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        winapi::um::fileapi::GetFileInformationByHandle(
            file.as_raw_handle() as winapi::um::winnt::HANDLE,
            &mut info,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(FileIdentity {
        storage: info.dwVolumeSerialNumber as u64,
        file: ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64,
    })
}

#[cfg(unix)]
fn file_identity(file: &std::fs::File) -> io::Result<FileIdentity> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata()?;
    Ok(FileIdentity {
        storage: metadata.dev(),
        file: metadata.ino(),
    })
}

#[cfg(not(any(unix, windows)))]
fn file_identity(file: &std::fs::File) -> io::Result<FileIdentity> {
    let metadata = file.metadata()?;
    let modified = metadata
        .modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    Ok(FileIdentity {
        storage: metadata.len(),
        file: modified,
    })
}

fn file_snapshot(path: &Path) -> ResultType<(FileIdentity, u64, u128)> {
    let file = std::fs::File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        bail!("destination is no longer a regular file");
    }
    let modified = metadata.modified()?.duration_since(UNIX_EPOCH)?.as_nanos();
    Ok((file_identity(&file)?, metadata.len(), modified))
}

#[derive(Clone, Debug)]
struct PendingFileConflict {
    file_num: i32,
    path: PathBuf,
    identity: FileIdentity,
    size: u64,
    modified: u128,
    token: String,
}

#[cfg(windows)]
fn move_file_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    let source: Vec<u16> = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let ok = unsafe { winapi::um::winbase::MoveFileW(source.as_ptr(), destination.as_ptr()) };
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn move_file_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    match std::fs::hard_link(source, destination) {
        Ok(()) => match std::fs::remove_file(source) {
            Ok(()) => Ok(()),
            Err(err) => {
                let _ = std::fs::remove_file(destination);
                Err(err)
            }
        },
        Err(err) if err.kind() == io::ErrorKind::AlreadyExists => Err(err),
        Err(_) => {
            // Hard links are not available on every filesystem. Reserve the
            // destination first so the fallback copy can never overwrite an
            // unrelated file, then remove the source only after the copy is
            // durable.
            let source_metadata = std::fs::metadata(source)?;
            let mut source_file = std::fs::File::open(source)?;
            let mut destination_file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(destination)?;
            if let Err(err) = std::io::copy(&mut source_file, &mut destination_file) {
                let _ = std::fs::remove_file(destination);
                return Err(err);
            }
            if let Err(err) = destination_file.sync_all() {
                let _ = std::fs::remove_file(destination);
                return Err(err);
            }
            if let Err(err) = std::fs::set_permissions(destination, source_metadata.permissions()) {
                let _ = std::fs::remove_file(destination);
                return Err(err);
            }
            if let Ok(modified) = source_metadata.modified() {
                if let Err(err) = filetime::set_file_mtime(
                    destination,
                    filetime::FileTime::from_system_time(modified),
                ) {
                    let _ = std::fs::remove_file(destination);
                    return Err(err);
                }
            }
            match std::fs::remove_file(source) {
                Ok(()) => Ok(()),
                Err(err) => {
                    let _ = std::fs::remove_file(destination);
                    Err(err)
                }
            }
        }
    }
}

fn publish_with_rollback<F>(
    final_path: &Path,
    backup_path: Option<&Path>,
    publish: F,
) -> ResultType<()>
where
    F: FnOnce() -> io::Result<()>,
{
    let Err(publish_err) = publish() else {
        return Ok(());
    };
    if let Some(backup_path) = backup_path {
        if let Err(restore_err) = move_file_no_replace(backup_path, final_path) {
            bail!(
                "could not publish completed transfer ({publish_err}); previous destination is preserved at {} because restoring it also failed: {}",
                backup_path.display(),
                restore_err
            );
        }
    }
    Err(publish_err.into())
}

#[derive(Default, Debug, Clone, Copy, PartialEq, Eq)]
enum TransferDirection {
    #[default]
    Write,
    Read,
}

#[derive(Default, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TransferJob {
    pub id: i32,
    pub r#type: JobType,
    pub remote: String,
    pub data_source: DataSource,
    pub show_hidden: bool,
    pub is_remote: bool,
    pub is_last_job: bool,
    pub is_resume: bool,
    pub file_num: i32,
    #[serde(skip_serializing)]
    files: Vec<FileEntry>,
    pub conn_id: i32, // server only

    #[serde(skip_serializing)]
    data_stream: Option<DataStream>,
    pub total_size: u64,
    finished_size: u64,
    transferred: u64,
    enable_overwrite_detection: bool,
    file_confirmed: bool,
    // indicating the last file is skipped
    file_skipped: bool,
    file_is_waiting: bool,
    default_overwrite_strategy: Option<bool>,
    #[serde(skip_serializing)]
    digest: FileDigest,
    #[serde(skip_serializing)]
    digest_file_num: Option<i32>,
    #[serde(skip_serializing)]
    file_digests: HashMap<i32, FileDigest>,
    #[serde(skip_serializing)]
    pending_digest_worker: Option<JoinHandle<ResultType<(u64, u64, Vec<u8>, FileIdentity)>>>,
    #[serde(skip_serializing)]
    pending_digest_file_num: Option<i32>,
    #[serde(skip_serializing)]
    source_digest_snapshot: Option<SourceDigestSnapshot>,
    #[serde(skip_serializing)]
    pending_conflict: Option<PendingFileConflict>,
    #[serde(skip_serializing)]
    active_partial_token: Option<(i32, String)>,
    #[serde(skip_serializing)]
    write_content_hasher: Option<Sha256>,
    #[serde(skip_serializing)]
    write_content_hash_file_num: Option<i32>,
    #[serde(skip_serializing)]
    write_content_hash_bytes: u64,
    #[serde(skip_serializing)]
    ownership_token: String,
    #[serde(skip_serializing)]
    direction: TransferDirection,
    #[cfg(test)]
    #[serde(skip_serializing)]
    final_hash_rescan_count: u32,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct TransferJobMeta {
    #[serde(default)]
    pub id: i32,
    #[serde(default)]
    pub remote: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub show_hidden: bool,
    #[serde(default)]
    pub file_num: i32,
    #[serde(default)]
    pub is_remote: bool,
    #[serde(default)]
    pub ownership_token: String,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct RemoveJobMeta {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub is_remote: bool,
    #[serde(default)]
    pub no_confirm: bool,
}

#[inline]
fn get_ext(name: &str) -> &str {
    if let Some(i) = name.rfind('.') {
        return &name[i + 1..];
    }
    ""
}

#[inline]
fn is_compressed_file(name: &str) -> bool {
    let compressed_exts = ["xz", "gz", "zip", "7z", "rar", "bz2", "tgz", "png", "jpg"];
    let ext = get_ext(name);
    compressed_exts.contains(&ext)
}

pub fn validate_file_name_no_traversal(name: &str) -> ResultType<()> {
    if name.bytes().any(|b| b == 0) {
        bail!("file name contains null bytes");
    }
    let has_traversal = name
        .split(|c: char| c == '/' || (cfg!(windows) && c == '\\'))
        .filter(|s| !s.is_empty())
        .any(|s| s == "..");
    if has_traversal {
        bail!("path traversal detected in file name");
    }
    #[cfg(windows)]
    {
        if name.len() >= 2 {
            let bytes = name.as_bytes();
            if bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
                bail!("absolute path detected in file name");
            }
        }
        if name.starts_with('/') || name.starts_with('\\') {
            bail!("absolute path detected in file name");
        }
    }
    #[cfg(not(windows))]
    if name.starts_with('/') {
        bail!("absolute path detected in file name");
    }
    Ok(())
}

fn validate_transfer_file_names(files: &[FileEntry]) -> ResultType<()> {
    // Single-file transfer may use an empty relative name, because
    // the destination file path is carried by transfer metadata.
    if files.len() == 1 && files.first().map_or(false, |f| f.name.is_empty()) {
        return Ok(());
    }
    for file in files {
        if file.name.is_empty() {
            bail!("empty file name in multi-file transfer");
        }
        validate_file_name_no_traversal(&file.name)?;
    }
    Ok(())
}

#[inline]
fn validate_fs_path_argument(path: &str, arg_name: &str) -> ResultType<()> {
    if path.is_empty() {
        bail!("{arg_name} cannot be empty");
    }
    if path.bytes().any(|b| b == 0) {
        bail!("{arg_name} contains null bytes");
    }
    Ok(())
}

fn validate_no_symlink_components(base: &PathBuf, name: &str) -> ResultType<()> {
    if name.is_empty() {
        return Ok(());
    }
    let mut current = base.clone();
    for component in Path::new(name).components() {
        match component {
            std::path::Component::Normal(seg) => {
                current.push(seg);
                // Best-effort guard: path-based checks are inherently TOCTOU-prone
                // if local filesystem state changes between validation and write.
                match std::fs::symlink_metadata(&current) {
                    Ok(meta) => {
                        // This is inherent to filesystem-based checks and acknowledged as a limitation.
                        // For true protection, you'd need openat(2) / O_NOFOLLOW at write time.
                        if meta.file_type().is_symlink() {
                            bail!("symlink path component is not allowed");
                        }
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                        // Component does not exist yet, continue best-effort validation.
                    }
                    Err(err) => {
                        bail!(
                            "failed to validate path component '{}': {}",
                            current.display(),
                            err
                        );
                    }
                }
            }
            std::path::Component::CurDir => {}
            _ => {
                bail!("invalid file name component");
            }
        }
    }
    Ok(())
}

/// Validate an untrusted relative file name and existing path components before joining it.
pub fn join_validated_path(base: &PathBuf, name: &str) -> ResultType<PathBuf> {
    validate_file_name_no_traversal(name)?;
    validate_no_symlink_components(base, name)?;
    Ok(TransferJob::join(base, name))
}

impl TransferJob {
    #[allow(clippy::too_many_arguments)]
    pub fn new_write(
        id: i32,
        r#type: JobType,
        remote: String,
        data_source: DataSource,
        file_num: i32,
        show_hidden: bool,
        is_remote: bool,
        enable_overwrite_detection: bool,
    ) -> Self {
        log::info!("new write {}", data_source);
        Self {
            id,
            r#type,
            remote,
            data_source,
            file_num,
            show_hidden,
            is_remote,
            files: Vec::new(),
            total_size: 0,
            enable_overwrite_detection,
            ownership_token: hbb_common::uuid::Uuid::new_v4().to_string(),
            direction: TransferDirection::Write,
            ..Default::default()
        }
    }

    pub fn with_files(mut self, files: Vec<FileEntry>) -> ResultType<Self> {
        self.set_files(files)?;
        Ok(self)
    }

    pub fn new_read(
        id: i32,
        r#type: JobType,
        remote: String,
        data_source: DataSource,
        file_num: i32,
        show_hidden: bool,
        is_remote: bool,
        enable_overwrite_detection: bool,
    ) -> ResultType<Self> {
        log::info!("new read {}", data_source);
        let (files, total_size) = match &data_source {
            DataSource::FilePath(p) => {
                let p = p.to_str().ok_or(anyhow!("Invalid path"))?;
                let files = get_recursive_files(p, show_hidden)?;
                let total_size = files.iter().map(|x| x.size).sum();
                (files, total_size)
            }
            DataSource::MemoryCursor(c) => (Vec::new(), c.get_ref().len() as u64),
        };
        Ok(Self {
            id,
            r#type,
            remote,
            data_source,
            file_num,
            show_hidden,
            is_remote,
            files,
            total_size,
            enable_overwrite_detection,
            ownership_token: hbb_common::uuid::Uuid::new_v4().to_string(),
            direction: TransferDirection::Read,
            ..Default::default()
        })
    }

    pub fn restore_ownership_token(&mut self, token: &str) -> ResultType<()> {
        let parsed = hbb_common::uuid::Uuid::parse_str(token)
            .map_err(|_| anyhow!("invalid persisted transfer ownership token"))?;
        self.ownership_token = parsed.to_string();
        Ok(())
    }

    pub fn ownership_token(&self) -> &str {
        &self.ownership_token
    }

    pub async fn get_buf_data(self) -> ResultType<Option<Vec<u8>>> {
        match self.data_stream {
            Some(DataStream::BufStream(mut bs)) => {
                bs.flush().await?;
                Ok(Some(bs.into_inner().into_inner()))
            }
            _ => Ok(None),
        }
    }

    /// Flush any currently open destination stream before a pause is
    /// acknowledged. The job is removed from its active owner immediately
    /// afterwards, so taking the stream here also guarantees the file handle is
    /// closed before the peer is told the transfer is quiescent.
    pub async fn sync_partial_for_pause(&mut self) -> ResultType<()> {
        let result = if let Some(stream) = self.data_stream.as_mut() {
            match stream {
                DataStream::FileStream(file) => file.sync_all().await.map_err(Into::into),
                DataStream::BufStream(buf) => buf.flush().await.map_err(Into::into),
            }
        } else {
            Ok(())
        };
        self.data_stream.take();
        result
    }

    #[inline]
    pub fn files(&self) -> &Vec<FileEntry> {
        &self.files
    }

    #[inline]
    pub fn set_files(&mut self, files: Vec<FileEntry>) -> ResultType<()> {
        validate_transfer_file_names(&files)?;
        if let DataSource::FilePath(base) = &self.data_source {
            for file in &files {
                validate_no_symlink_components(base, &file.name)?;
            }
        }
        self.total_size = files.iter().map(|x| x.size).sum();
        self.files = files;
        Ok(())
    }

    #[inline]
    pub fn set_digest(&mut self, file_num: i32, size: u64, modified: u64) {
        self.set_digest_with_hash(file_num, size, modified, Vec::new());
    }

    #[inline]
    pub fn set_digest_with_hash(
        &mut self,
        file_num: i32,
        size: u64,
        modified: u64,
        content_sha256: Vec<u8>,
    ) {
        let digest = FileDigest {
            size,
            modified,
            content_sha256: content_sha256.into(),
            ..Default::default()
        };
        self.digest = digest.clone();
        self.digest_file_num = Some(file_num);
        self.file_digests.insert(file_num, digest);
    }

    fn source_identity_for_file(&self, file_num: i32) -> ResultType<(u64, u64)> {
        let index = usize::try_from(file_num).map_err(|_| anyhow!("invalid file number"))?;
        let entry = self
            .files
            .get(index)
            .ok_or_else(|| anyhow!("invalid file number"))?;
        if let Some(digest) = self.file_digests.get(&file_num) {
            return Ok((digest.size, digest.modified));
        }
        Ok((entry.size, entry.modified_time))
    }

    fn source_sha256_for_file(&self, file_num: i32) -> Vec<u8> {
        self.file_digests
            .get(&file_num)
            .map(|digest| digest.content_sha256.clone())
            .unwrap_or_default()
    }

    fn partial_paths(&self, file_num: i32) -> ResultType<(PathBuf, PathBuf, PathBuf)> {
        if self.r#type == JobType::Printer {
            bail!("printer jobs do not use partial files");
        }
        let DataSource::FilePath(base) = &self.data_source else {
            bail!("partial files require a filesystem destination");
        };
        let index = usize::try_from(file_num).map_err(|_| anyhow!("invalid file number"))?;
        let entry = self
            .files
            .get(index)
            .ok_or_else(|| anyhow!("invalid file number"))?;
        let final_path = self
            .resolve_entry_path(base, &entry.name)
            .ok_or_else(|| anyhow!("invalid destination path"))?;
        let final_text = get_string(&final_path);
        Ok((
            final_path,
            PathBuf::from(format!("{final_text}.download")),
            PathBuf::from(format!("{final_text}.digest")),
        ))
    }

    fn ownership_for_partial(
        &self,
        file_num: i32,
        final_path: &Path,
        partial: &std::fs::File,
    ) -> ResultType<PartialFileOwnership> {
        let metadata = partial.metadata()?;
        if !metadata.is_file() {
            bail!("partial artifact is not a regular file");
        }
        let identity = file_identity(&partial)?;
        let (source_size, source_modified) = self.source_identity_for_file(file_num)?;
        Ok(PartialFileOwnership {
            version: PARTIAL_OWNERSHIP_VERSION,
            token: self.ownership_token.clone(),
            creator_job_id: self.id,
            remote: self.remote.clone(),
            destination: get_string(final_path),
            file_num,
            source_size,
            source_modified,
            source_sha256: self.source_sha256_for_file(file_num),
            partial_storage: identity.storage,
            partial_file: identity.file,
        })
    }

    fn ownership_matches_job(
        &self,
        ownership: &PartialFileOwnership,
        file_num: i32,
        final_path: &Path,
    ) -> bool {
        let Ok((source_size, source_modified)) = self.source_identity_for_file(file_num) else {
            return false;
        };
        ownership.version == PARTIAL_OWNERSHIP_VERSION
            && !ownership.token.is_empty()
            && ownership.token == self.ownership_token
            && ownership.remote == self.remote
            && ownership.destination == get_string(final_path)
            && ownership.file_num == file_num
            && ownership.source_size == source_size
            && ownership.source_modified == source_modified
            && ownership.source_sha256 == self.source_sha256_for_file(file_num)
    }

    fn validate_partial_ownership(
        &self,
        file_num: i32,
        require_active_claim: bool,
    ) -> ResultType<(FileDigest, PartialFileOwnership)> {
        let (final_path, partial_path, digest_path) = self.partial_paths(file_num)?;
        let content = std::fs::read_to_string(&digest_path)?;
        let digest: FileDigest = serde_json::from_str(&content)?;
        let ownership = digest
            .ownership
            .clone()
            .ok_or_else(|| anyhow!("partial ownership record is missing"))?;
        if !self.ownership_matches_job(&ownership, file_num, &final_path) {
            bail!("partial ownership does not match this transfer");
        }
        if require_active_claim
            && self
                .active_partial_token
                .as_ref()
                .map(|(claimed_file_num, token)| {
                    *claimed_file_num == file_num && token == &ownership.token
                })
                != Some(true)
        {
            bail!("partial is not claimed by this active job");
        }
        let partial = std::fs::File::open(&partial_path)?;
        let metadata = partial.metadata()?;
        if !metadata.is_file() {
            bail!("partial artifact is not a regular file");
        }
        let identity = file_identity(&partial)?;
        if identity.storage != ownership.partial_storage || identity.file != ownership.partial_file
        {
            bail!("partial artifact identity changed");
        }
        Ok((digest, ownership))
    }

    pub fn capture_pending_conflict(&mut self, file_num: i32, path: &Path) -> ResultType<String> {
        let (identity, size, modified) = file_snapshot(path)?;
        let token = hbb_common::uuid::Uuid::new_v4().to_string();
        self.pending_conflict = Some(PendingFileConflict {
            file_num,
            path: path.to_path_buf(),
            identity,
            size,
            modified,
            token: token.clone(),
        });
        Ok(token)
    }

    pub fn clear_pending_conflict(&mut self, file_num: i32) {
        if self
            .pending_conflict
            .as_ref()
            .map(|snapshot| snapshot.file_num == file_num)
            .unwrap_or(false)
        {
            self.pending_conflict = None;
        }
    }

    pub fn validate_pending_conflict(&self, file_num: i32) -> ResultType<()> {
        let snapshot = self
            .pending_conflict
            .as_ref()
            .ok_or_else(|| anyhow!("file conflict is no longer active"))?;
        if snapshot.file_num != file_num {
            bail!("file conflict no longer matches the requested file");
        }
        let (identity, size, modified) = file_snapshot(&snapshot.path)?;
        if identity != snapshot.identity || size != snapshot.size || modified != snapshot.modified {
            bail!("destination changed since the conflict prompt; review the conflict again");
        }
        Ok(())
    }

    pub fn validate_pending_conflict_token(
        &self,
        file_num: i32,
        conflict_token: &str,
    ) -> ResultType<()> {
        self.validate_pending_conflict(file_num)?;
        let snapshot = self
            .pending_conflict
            .as_ref()
            .ok_or_else(|| anyhow!("file conflict is no longer active"))?;
        // Empty tokens are accepted only as the legacy compatibility path.
        // New peers echo the opaque token carried by FileTransferDigest, so a
        // stale dialog/request cannot authorize a later conflict snapshot.
        if !conflict_token.is_empty() && snapshot.token != conflict_token {
            bail!("file conflict token no longer matches the active conflict");
        }
        Ok(())
    }

    pub fn pending_conflict_token(&self, file_num: i32) -> Option<String> {
        self.pending_conflict
            .as_ref()
            .filter(|snapshot| snapshot.file_num == file_num)
            .map(|snapshot| snapshot.token.clone())
    }

    pub fn validate_pending_conflict_if_present(&self, file_num: i32) -> ResultType<()> {
        match self.pending_conflict.as_ref() {
            Some(snapshot) if snapshot.file_num == file_num => {
                self.validate_pending_conflict(file_num)
            }
            Some(_) => bail!("file conflict no longer matches the requested file"),
            None => Ok(()),
        }
    }

    #[inline]
    pub fn id(&self) -> i32 {
        self.id
    }

    #[inline]
    pub fn total_size(&self) -> u64 {
        self.total_size
    }

    #[inline]
    pub fn finished_size(&self) -> u64 {
        self.finished_size
    }

    #[inline]
    pub fn transferred(&self) -> u64 {
        self.transferred
    }

    #[inline]
    pub fn file_num(&self) -> i32 {
        self.file_num
    }

    fn resolve_entry_path(&self, base: &PathBuf, name: &str) -> Option<PathBuf> {
        if self.r#type == JobType::Generic {
            match join_validated_path(base, name) {
                Ok(path) => Some(path),
                Err(err) => {
                    log::error!("Invalid file name in transfer job {}: {}", self.id, err);
                    None
                }
            }
        } else {
            Some(Self::join(base, name))
        }
    }

    pub async fn modify_time(&mut self) -> ResultType<()> {
        if self.r#type == JobType::Printer {
            return Ok(());
        }
        if self.file_num < 0 || self.file_num as usize >= self.files.len() {
            if self.file_skipped {
                return Ok(());
            }
            bail!("completed transfer has no current file to finalize");
        }
        if self
            .active_partial_token
            .as_ref()
            .map(|(file_num, _)| *file_num == self.file_num)
            != Some(true)
        {
            bail!("completed transfer has no owned partial to finalize");
        }

        let file_num = self.file_num;
        let modified_time = self.files[file_num as usize].modified_time;
        let (final_path, partial_path, digest_path) = self.partial_paths(file_num)?;
        let (_, ownership) = self.validate_partial_ownership(file_num, true)?;
        let partial_metadata = std::fs::metadata(&partial_path)?;
        if partial_metadata.len() != ownership.source_size {
            bail!(
                "partial transfer is incomplete: expected {} bytes, found {}",
                ownership.source_size,
                partial_metadata.len()
            );
        }

        if !ownership.source_sha256.is_empty() {
            if ownership.source_sha256.len() != 32 {
                bail!("partial source content hash is invalid");
            }
            if self.write_content_hash_file_num == Some(file_num)
                && self.write_content_hash_bytes == ownership.source_size
            {
                let streamed_hash = self
                    .write_content_hasher
                    .as_ref()
                    .cloned()
                    .ok_or_else(|| anyhow!("streamed content hash state is missing"))?
                    .finalize()
                    .to_vec();
                if streamed_hash != ownership.source_sha256 {
                    bail!("partial content hash does not match the source content hash");
                }
            }

            // The streamed hash proves which bytes this job wrote, but another
            // process can still alter the partial before publication. Verify
            // the owned file on disk before it can replace the destination.
            let partial_path_for_hash = partial_path.clone();
            #[cfg(test)]
            {
                self.final_hash_rescan_count += 1;
            }
            let expected_identity = FileIdentity {
                storage: ownership.partial_storage,
                file: ownership.partial_file,
            };
            let expected_size = ownership.source_size;
            let actual_hash =
                hbb_common::tokio::task::spawn_blocking(move || -> ResultType<Vec<u8>> {
                    let mut partial = std::fs::File::open(&partial_path_for_hash)?;
                    if file_identity(&partial)? != expected_identity {
                        bail!("partial artifact identity changed before final verification");
                    }
                    let before = partial.metadata()?;
                    if !before.is_file() || before.len() != expected_size {
                        bail!("partial artifact changed before final verification");
                    }
                    let mut hasher = Sha256::new();
                    let mut buf = vec![0u8; 1024 * 1024];
                    loop {
                        let read = std::io::Read::read(&mut partial, &mut buf)?;
                        if read == 0 {
                            break;
                        }
                        hasher.update(&buf[..read]);
                    }
                    let after = partial.metadata()?;
                    if after.len() != before.len() || file_identity(&partial)? != expected_identity
                    {
                        bail!("partial artifact changed during final verification");
                    }
                    Ok(hasher.finalize().to_vec())
                })
                .await
                .map_err(|err| anyhow!("final content hash worker failed: {err}"))??;
            if actual_hash != ownership.source_sha256 {
                bail!("partial content hash does not match the source content hash");
            }
        }

        // Prepare the completed partial before touching an existing
        // destination. A timestamp failure must leave the user's current file
        // exactly where it was.
        filetime::set_file_mtime(
            &partial_path,
            filetime::FileTime::from_unix_time(modified_time as _, 0),
        )?;

        let mut replaced_destination = None;
        match self.pending_conflict.clone() {
            Some(snapshot) if snapshot.file_num == file_num => {
                self.validate_pending_conflict(file_num)?;

                // Move the confirmed destination to a unique sibling before
                // publishing the completed partial. This gives us a rollback
                // copy if the publish step fails, and lets us re-check the
                // exact file identity after the path move to close the most
                // damaging validate-then-delete race.
                let backup_path = self
                    .keep_both_existing_destination(file_num)?
                    .ok_or_else(|| anyhow!("destination disappeared before finalization"))?;
                let moved_snapshot = file_snapshot(&backup_path);
                match moved_snapshot {
                    Ok((identity, size, modified))
                        if identity == snapshot.identity
                            && size == snapshot.size
                            && modified == snapshot.modified =>
                    {
                        replaced_destination = Some(backup_path);
                    }
                    result => {
                        match move_file_no_replace(&backup_path, &final_path) {
                            Ok(()) => {}
                            Err(restore_err) => {
                                bail!(
                                    "destination changed during finalization and could not be restored; preserved previous data at {}: {}",
                                    backup_path.display(),
                                    restore_err
                                );
                            }
                        }
                        if let Err(err) = result {
                            return Err(err.into());
                        }
                        bail!(
                            "destination changed since the conflict prompt; review the conflict again"
                        );
                    }
                }
            }
            Some(_) => bail!("file conflict no longer matches the requested file"),
            None if final_path.exists() => {
                bail!("destination appeared after transfer started; review the conflict again");
            }
            None => {}
        }

        publish_with_rollback(&final_path, replaced_destination.as_deref(), || {
            move_file_no_replace(&partial_path, &final_path)
        })?;

        if let Some(backup_path) = replaced_destination {
            if let Err(err) = std::fs::remove_file(&backup_path) {
                log::warn!(
                    "Published transfer job {} but could not remove replacement backup {}: {}",
                    self.id,
                    backup_path.display(),
                    err
                );
            }
        }
        std::fs::remove_file(&digest_path)?;
        self.active_partial_token = None;
        self.write_content_hasher = None;
        self.write_content_hash_file_num = None;
        self.write_content_hash_bytes = 0;
        self.file_digests.remove(&file_num);
        if self.digest_file_num == Some(file_num) {
            self.digest = FileDigest::default();
            self.digest_file_num = None;
        }
        self.clear_pending_conflict(file_num);
        Ok(())
    }

    pub fn remove_download_file(&self) {
        if self.r#type == JobType::Printer {
            return;
        }
        if self.file_num < 0 || self.file_num as usize >= self.files.len() {
            return;
        }
        let Ok((_, partial_path, digest_path)) = self.partial_paths(self.file_num) else {
            return;
        };
        if let Err(err) = self.validate_partial_ownership(self.file_num, true) {
            log::warn!(
                "Preserving partial artifacts for job {} because ownership could not be proven: {}",
                self.id,
                err
            );
            return;
        }
        match std::fs::remove_file(&partial_path) {
            Ok(()) => {
                if let Err(err) = std::fs::remove_file(&digest_path) {
                    log::warn!(
                        "Removed owned partial for job {} but could not remove sidecar {}: {}",
                        self.id,
                        digest_path.display(),
                        err
                    );
                }
            }
            Err(err) => {
                log::warn!(
                    "Could not remove owned partial for job {} at {}: {}",
                    self.id,
                    partial_path.display(),
                    err
                );
            }
        }
    }

    /// Moves an existing completed destination to a unique sibling name so a
    /// new transfer can safely keep the original destination name. This never
    /// overwrites an existing sibling and never touches this job's
    /// `.download`/`.digest` partial artifacts.
    pub fn keep_both_existing_destination(&self, file_num: i32) -> ResultType<Option<PathBuf>> {
        if self.r#type == JobType::Printer {
            bail!("keep both is not supported for printer jobs");
        }
        let DataSource::FilePath(base) = &self.data_source else {
            bail!("keep both requires a filesystem destination");
        };
        let index = usize::try_from(file_num).map_err(|_| anyhow!("invalid file number"))?;
        let entry = self
            .files
            .get(index)
            .ok_or_else(|| anyhow!("invalid file number"))?;
        let path = self
            .resolve_entry_path(base, &entry.name)
            .ok_or_else(|| anyhow!("invalid destination path"))?;
        if !path.exists() {
            return Ok(None);
        }
        if !path.is_file() {
            bail!("existing destination is not a regular file");
        }

        let stem = path
            .file_stem()
            .or_else(|| path.file_name())
            .ok_or_else(|| anyhow!("destination has no file name"))?;
        let extension = path.extension();

        for suffix in 1..=10_000u32 {
            let mut name = std::ffi::OsString::from(stem);
            name.push(format!(" ({suffix})"));
            if let Some(extension) = extension {
                name.push(".");
                name.push(extension);
            }
            let candidate = path.with_file_name(name);

            #[cfg(windows)]
            {
                match move_file_no_replace(&path, &candidate) {
                    Ok(()) => return Ok(Some(candidate)),
                    Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(err) => return Err(err.into()),
                }
            }

            #[cfg(not(windows))]
            match std::fs::hard_link(&path, &candidate) {
                Ok(()) => {
                    if let Err(err) = std::fs::remove_file(&path) {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(err.into());
                    }
                    return Ok(Some(candidate));
                }
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => {
                    // Some filesystems or policies do not permit hard links.
                    // Reserve the candidate with create_new so the fallback
                    // copy still cannot overwrite somebody else's file.
                    let source_metadata = std::fs::metadata(&path)?;
                    let mut source = std::fs::File::open(&path)?;
                    let mut destination = match std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&candidate)
                    {
                        Ok(file) => file,
                        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                        Err(err) => return Err(err.into()),
                    };
                    if let Err(err) = std::io::copy(&mut source, &mut destination) {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(err.into());
                    }
                    if let Err(err) = destination.sync_all() {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(err.into());
                    }
                    if let Err(err) =
                        std::fs::set_permissions(&candidate, source_metadata.permissions())
                    {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(err.into());
                    }
                    if let Ok(modified) = source_metadata.modified() {
                        if let Err(err) = filetime::set_file_mtime(
                            &candidate,
                            filetime::FileTime::from_system_time(modified),
                        ) {
                            let _ = std::fs::remove_file(&candidate);
                            return Err(err.into());
                        }
                    }
                    if let Err(err) = std::fs::remove_file(&path) {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(err.into());
                    }
                    return Ok(Some(candidate));
                }
            }
        }

        bail!("could not find a free keep-both destination name")
    }

    #[inline]
    pub fn set_finished_size_on_resume(&mut self) {
        if self.is_resume && self.file_num > 0 {
            let finished_size: u64 = self
                .files
                .iter()
                .take(self.file_num as usize)
                .map(|file| file.size)
                .sum();
            self.finished_size = finished_size;
        }
    }

    pub async fn write(&mut self, block: FileTransferBlock) -> ResultType<()> {
        if block.id != self.id {
            bail!("Wrong id");
        }
        match &self.data_source {
            DataSource::FilePath(p) => {
                let p = p.clone();
                let file_num = block.file_num as usize;
                if file_num >= self.files.len() {
                    bail!("Wrong file number");
                }
                if file_num != self.file_num as usize || self.data_stream.is_none() {
                    let had_stream = self.data_stream.is_some();
                    if let Some(DataStream::FileStream(file)) = self.data_stream.as_mut() {
                        file.sync_all().await?;
                    }
                    if had_stream {
                        self.data_stream.take();
                        self.modify_time().await?;
                    }
                    self.file_num = block.file_num;
                    let entry = &self.files[file_num];
                    let (path, digest_path, final_path) = if self.r#type == JobType::Printer {
                        (p.clone(), None, None)
                    } else {
                        let final_path = join_validated_path(&p, &entry.name)?;
                        // NOTE: We intentionally keep path-based validation + regular file open here.
                        // This still has a known TOCTOU window for symlink races, but avoids a large
                        // cross-platform rewrite for now.
                        // Revisit with descriptor/handle-based no-follow open in future hardening.
                        if let Some(pp) = final_path.parent() {
                            std::fs::create_dir_all(pp)?;
                        }
                        let file_path = get_string(&final_path);
                        (
                            PathBuf::from(format!("{}.download", &file_path)),
                            Some(PathBuf::from(format!("{}.digest", &file_path))),
                            Some(final_path),
                        )
                    };
                    if let Some(dp) = digest_path.as_ref() {
                        if path.exists() || dp.exists() {
                            bail!(
                                "partial transfer artifacts already exist for {}; resume or remove them explicitly",
                                final_path
                                    .as_ref()
                                    .map(|value| value.display().to_string())
                                    .unwrap_or_else(|| path.display().to_string())
                            );
                        }
                    }
                    let file = if self.r#type == JobType::Printer {
                        File::create(&path).await?
                    } else {
                        let std_file = std::fs::OpenOptions::new()
                            .write(true)
                            .create_new(true)
                            .open(&path)?;
                        let dp = digest_path
                            .as_ref()
                            .ok_or_else(|| anyhow!("missing ownership sidecar path"))?;
                        let ownership = match self.ownership_for_partial(
                            block.file_num,
                            final_path
                                .as_deref()
                                .ok_or_else(|| anyhow!("missing final destination"))?,
                            &std_file,
                        ) {
                            Ok(ownership) => ownership,
                            Err(err) => {
                                drop(std_file);
                                let _ = std::fs::remove_file(&path);
                                return Err(err);
                            }
                        };
                        let mut digest = self
                            .file_digests
                            .get(&block.file_num)
                            .cloned()
                            .or_else(|| {
                                (self.digest_file_num == Some(block.file_num))
                                    .then(|| self.digest.clone())
                            })
                            .unwrap_or_default();
                        digest.rustdesk_owned_partial = true;
                        digest.ownership = Some(ownership.clone());
                        let payload = serde_json::to_vec(&digest)?;
                        let mut sidecar = match std::fs::OpenOptions::new()
                            .write(true)
                            .create_new(true)
                            .open(dp)
                        {
                            Ok(sidecar) => sidecar,
                            Err(err) => {
                                drop(std_file);
                                let _ = std::fs::remove_file(&path);
                                return Err(err.into());
                            }
                        };
                        if let Err(err) = std::io::Write::write_all(&mut sidecar, &payload)
                            .and_then(|_| sidecar.sync_all())
                        {
                            drop(sidecar);
                            drop(std_file);
                            let _ = std::fs::remove_file(dp);
                            let _ = std::fs::remove_file(&path);
                            return Err(err.into());
                        }
                        self.active_partial_token = Some((block.file_num, ownership.token.clone()));
                        if ownership.source_sha256.len() == 32 {
                            self.write_content_hasher = Some(Sha256::new());
                            self.write_content_hash_file_num = Some(block.file_num);
                            self.write_content_hash_bytes = 0;
                        } else {
                            self.write_content_hasher = None;
                            self.write_content_hash_file_num = None;
                            self.write_content_hash_bytes = 0;
                        }
                        self.digest = digest;
                        self.digest_file_num = Some(block.file_num);
                        File::from_std(std_file)
                    };
                    self.data_stream = Some(DataStream::FileStream(file));
                }
            }
            DataSource::MemoryCursor(c) => {
                if self.data_stream.is_none() {
                    self.data_stream = Some(DataStream::BufStream(TokioBufStream::new(c.clone())));
                }
            }
        }
        if block.compressed {
            let tmp = decompress(&block.data);
            self.data_stream
                .as_mut()
                .ok_or(anyhow!("data stream is None"))?
                .write_all(&tmp)
                .await?;
            self.finished_size += tmp.len() as u64;
            if self.write_content_hash_file_num == Some(block.file_num) {
                if let Some(hasher) = self.write_content_hasher.as_mut() {
                    hasher.update(&tmp);
                    self.write_content_hash_bytes += tmp.len() as u64;
                }
            }
        } else {
            self.data_stream
                .as_mut()
                .ok_or(anyhow!("file is None"))?
                .write_all(&block.data)
                .await?;
            self.finished_size += block.data.len() as u64;
            if self.write_content_hash_file_num == Some(block.file_num) {
                if let Some(hasher) = self.write_content_hasher.as_mut() {
                    hasher.update(&block.data);
                    self.write_content_hash_bytes += block.data.len() as u64;
                }
            }
        }
        self.transferred += block.data.len() as u64;
        Ok(())
    }

    #[inline]
    pub fn join(p: &PathBuf, name: &str) -> PathBuf {
        if name.is_empty() {
            p.clone()
        } else {
            p.join(name)
        }
    }

    /// Open the data stream for the current file.
    /// Returns Ok(true) if job is done, Ok(false) otherwise.
    async fn open_data_stream(&mut self) -> ResultType<bool> {
        let file_num = self.file_num as usize;
        match &mut self.data_source {
            DataSource::FilePath(p) => {
                if file_num >= self.files.len() {
                    // job done
                    self.data_stream.take();
                    return Ok(true);
                };
                if self.data_stream.is_none() {
                    match File::open(Self::join(p, &self.files[file_num].name)).await {
                        Ok(file) => {
                            self.data_stream = Some(DataStream::FileStream(file));
                            self.file_confirmed = false;
                            self.file_is_waiting = false;
                        }
                        // On open error, behave the same as validation failure: advance
                        // to next file and return the error.
                        Err(err) => {
                            self.file_num += 1;
                            self.file_confirmed = false;
                            self.file_is_waiting = false;
                            return Err(err.into());
                        }
                    }
                }
            }
            DataSource::MemoryCursor(c) => {
                if self.data_stream.is_none() {
                    let mut t = std::io::Cursor::new(Vec::new());
                    std::mem::swap(&mut t, c);
                    self.data_stream = Some(DataStream::BufStream(TokioBufStream::new(t)));
                }
            }
        }
        Ok(false)
    }

    /// Start hashing the current file on a blocking worker after proving the
    /// independently opened hash handle resolves to the same file identity as
    /// the active source stream.
    async fn spawn_current_digest_worker(
        &self,
    ) -> ResultType<JoinHandle<ResultType<(u64, u64, Vec<u8>, FileIdentity)>>> {
        let active_identity = match self.data_stream.as_ref().ok_or(anyhow!("file is None"))? {
            DataStream::FileStream(file) => {
                let cloned = file.try_clone().await?;
                let std_file = cloned.into_std().await;
                file_identity(&std_file)?
            }
            DataStream::BufStream(_) => bail!("No digest for buf stream"),
        };
        let DataSource::FilePath(base) = &self.data_source else {
            bail!("No digest for non-file source");
        };
        let file_num =
            usize::try_from(self.file_num).map_err(|_| anyhow!("invalid file number"))?;
        let entry = self
            .files
            .get(file_num)
            .ok_or_else(|| anyhow!("invalid file number"))?;
        let path = Self::join(base, &entry.name);

        Ok(hbb_common::tokio::task::spawn_blocking(
            move || -> ResultType<(u64, u64, Vec<u8>, FileIdentity)> {
                let mut file = std::fs::File::open(&path)?;
                if file_identity(&file)? != active_identity {
                    bail!("source path changed while preparing transfer digest");
                }
                let before = file.metadata()?;
                if !before.is_file() {
                    bail!("transfer source is not a regular file");
                }
                let before_modified = before.modified()?;
                let mut hasher = Sha256::new();
                let mut buf = vec![0u8; 1024 * 1024];
                loop {
                    let read = std::io::Read::read(&mut file, &mut buf)?;
                    if read == 0 {
                        break;
                    }
                    hasher.update(&buf[..read]);
                }
                let after = file.metadata()?;
                if after.len() != before.len() || after.modified()? != before_modified {
                    bail!("source changed while computing transfer digest");
                }
                let last_modified = before_modified
                    .duration_since(SystemTime::UNIX_EPOCH)?
                    .as_secs();
                Ok((
                    last_modified,
                    before.len(),
                    hasher.finalize().to_vec(),
                    active_identity,
                ))
            },
        ))
    }

    /// Get current file's metadata plus a strong content identity. This helper
    /// is retained for focused validation; production transfer ticks use the
    /// non-blocking poll path below.
    #[cfg(test)]
    async fn get_current_digest(&self) -> ResultType<(u64, u64, Vec<u8>)> {
        let (modified, size, hash, _) = self
            .spawn_current_digest_worker()
            .await?
            .await
            .map_err(|err| anyhow!("transfer digest worker failed: {err}"))??;
        Ok((modified, size, hash))
    }

    /// Start or poll the whole-file content digest without awaiting the hash in
    /// the connection/file-transfer event loop. The first call always schedules
    /// work and returns `None`; later calls collect the result only after the
    /// worker has finished.
    async fn poll_current_digest(&mut self) -> ResultType<Option<(u64, u64, Vec<u8>)>> {
        if let Some(worker_file_num) = self.pending_digest_file_num {
            if worker_file_num != self.file_num {
                if let Some(worker) = self.pending_digest_worker.take() {
                    worker.abort();
                }
                self.pending_digest_file_num = None;
            }
        }

        if self.pending_digest_worker.is_none() {
            let worker = self.spawn_current_digest_worker().await?;
            self.pending_digest_file_num = Some(self.file_num);
            self.pending_digest_worker = Some(worker);
            self.set_file_is_waiting(true);
            return Ok(None);
        }

        if !self
            .pending_digest_worker
            .as_ref()
            .map(|worker| worker.is_finished())
            .unwrap_or(false)
        {
            return Ok(None);
        }

        let worker_file_num = self.pending_digest_file_num;
        let worker = self
            .pending_digest_worker
            .take()
            .ok_or_else(|| anyhow!("transfer digest worker disappeared"))?;
        self.pending_digest_file_num = None;
        match worker.await {
            Ok(result) => match result {
                Ok((modified, size, hash, identity)) => {
                    let file_num = worker_file_num
                        .ok_or_else(|| anyhow!("transfer digest file number disappeared"))?;
                    self.source_digest_snapshot = Some(SourceDigestSnapshot {
                        file_num,
                        identity,
                        size,
                        modified,
                    });
                    Ok(Some((modified, size, hash)))
                }
                Err(err) => {
                    self.set_file_is_waiting(false);
                    Err(err)
                }
            },
            Err(err) => {
                self.set_file_is_waiting(false);
                Err(anyhow!("transfer digest worker failed: {err}"))
            }
        }
    }

    async fn init_data_stream(&mut self, stream: &mut hbb_common::Stream) -> ResultType<()> {
        if self.open_data_stream().await? {
            return Ok(());
        }
        if self.r#type == JobType::Generic
            && self.enable_overwrite_detection
            && !self.file_confirmed()
        {
            if self.pending_digest_worker.is_some() || !self.file_is_waiting() {
                if let Some(digest) = self.poll_current_digest().await? {
                    self.send_current_digest(stream, digest).await?;
                    self.set_file_is_waiting(true);
                }
            }
        }
        Ok(())
    }

    /// Initialize data stream for CM (Connection Manager) scenario.
    /// Returns digest info (last_modified, file_size) if overwrite detection is enabled,
    /// so caller can send it via IPC instead of network stream.
    /// Returns Ok(None) if job is done or already initialized.
    pub async fn init_data_stream_for_cm(&mut self) -> ResultType<Option<(u64, u64, Vec<u8>)>> {
        if self.open_data_stream().await? {
            return Ok(None);
        }
        // For overwrite detection, return digest info instead of sending via stream
        if self.r#type == JobType::Generic
            && self.enable_overwrite_detection
            && !self.file_confirmed()
        {
            if self.pending_digest_worker.is_some() || !self.file_is_waiting() {
                if let Some(digest) = self.poll_current_digest().await? {
                    self.set_file_is_waiting(true);
                    return Ok(Some(digest));
                }
            }
        }
        Ok(None)
    }

    pub async fn read(&mut self) -> ResultType<Option<FileTransferBlock>> {
        if self.r#type == JobType::Generic {
            if self.enable_overwrite_detection && !self.file_confirmed() {
                return Ok(None);
            }
        }

        let file_num = self.file_num as usize;
        let name = match &self.data_source {
            DataSource::FilePath(p) => {
                if file_num >= self.files.len() {
                    self.data_stream.take();
                    return Ok(None);
                };
                if self.files.len() == 1 && self.files[file_num].name.is_empty() {
                    p.file_name()
                        .map(|p| p.to_str().unwrap_or(""))
                        .unwrap_or("")
                } else {
                    &self.files[file_num].name
                }
            }
            DataSource::MemoryCursor(..) => "",
        };
        const BUF_SIZE: usize = 128 * 1024;
        let mut buf: Vec<u8> = vec![0; BUF_SIZE];
        let mut compressed = false;
        let mut offset: usize = 0;
        loop {
            match self
                .data_stream
                .as_mut()
                .ok_or(anyhow!("data stream is None"))?
                .read(&mut buf[offset..])
                .await
            {
                Err(err) => {
                    self.file_num += 1;
                    self.data_stream = None;
                    self.file_confirmed = false;
                    self.file_is_waiting = false;
                    return Err(err.into());
                }
                Ok(n) => {
                    offset += n;
                    if n == 0 || offset == BUF_SIZE {
                        break;
                    }
                }
            }
        }
        unsafe { buf.set_len(offset) };
        if offset == 0 {
            if matches!(self.data_source, DataSource::MemoryCursor(_)) {
                self.data_stream.take();
                return Ok(None);
            }
            self.file_num += 1;
            self.data_stream = None;
            self.file_confirmed = false;
            self.file_is_waiting = false;
        } else {
            self.finished_size += offset as u64;
            if matches!(self.data_source, DataSource::FilePath(_)) && !is_compressed_file(name) {
                let tmp = compress(&buf);
                if tmp.len() < buf.len() {
                    buf = tmp;
                    compressed = true;
                }
            }
            self.transferred += buf.len() as u64;
        }
        Ok(Some(FileTransferBlock {
            id: self.id,
            file_num: file_num as _,
            data: buf.into(),
            compressed,
            ..Default::default()
        }))
    }

    // Only for generic job and file stream
    async fn send_current_digest(
        &mut self,
        stream: &mut Stream,
        (last_modified, file_size, content_sha256): (u64, u64, Vec<u8>),
    ) -> ResultType<()> {
        let mut msg = Message::new();
        let mut resp = FileResponse::new();
        resp.set_digest(FileTransferDigest {
            id: self.id,
            file_num: self.file_num,
            last_modified,
            file_size,
            is_resume: self.is_resume,
            content_sha256: content_sha256.into(),
            ..Default::default()
        });
        msg.set_file_response(resp);
        stream.send(&msg).await?;
        log::info!(
            "id: {}, file_num: {}, digest message is sent. waiting for confirm. msg: {:?}",
            self.id,
            self.file_num,
            msg
        );
        Ok(())
    }

    pub fn set_overwrite_strategy(&mut self, overwrite_strategy: Option<bool>) {
        self.default_overwrite_strategy = overwrite_strategy;
    }

    pub fn default_overwrite_strategy(&self) -> Option<bool> {
        self.default_overwrite_strategy
    }

    pub fn set_file_confirmed(&mut self, file_confirmed: bool) {
        log::info!("id: {}, file_confirmed: {}", self.id, file_confirmed);
        self.file_confirmed = file_confirmed;
        self.file_skipped = false;
    }

    pub fn set_file_is_waiting(&mut self, file_is_waiting: bool) {
        self.file_is_waiting = file_is_waiting;
    }

    #[inline]
    pub fn file_is_waiting(&self) -> bool {
        self.file_is_waiting
    }

    #[inline]
    pub fn file_confirmed(&self) -> bool {
        self.file_confirmed
    }

    /// Indicating whether the last file is skipped
    #[inline]
    pub fn file_skipped(&self) -> bool {
        self.file_skipped
    }

    /// Indicating whether the whole task is skipped
    #[inline]
    pub fn job_skipped(&self) -> bool {
        self.file_skipped() && self.files.len() == 1
    }

    /// Check whether the job is completed after `read` returns `None`
    /// This is a helper function which gives additional lifecycle when the job reads `None`.
    /// If returns `true`, it means we can delete the job automatically. `False` otherwise.
    ///
    /// [`Note`]
    /// Conditions:
    /// 1. Files are not waiting for confirmation by peers.
    #[inline]
    pub fn job_completed(&self) -> bool {
        // has no error, Condition 2
        !self.enable_overwrite_detection || (!self.file_confirmed && !self.file_is_waiting)
    }

    /// Get job error message, useful for getting status when job had finished
    pub fn job_error(&self) -> Option<String> {
        if self.job_skipped() {
            return Some("skipped".to_string());
        }
        None
    }

    pub fn set_file_skipped(&mut self) -> bool {
        log::debug!("skip file {} in job {}", self.file_num, self.id);
        if self.digest_file_num == Some(self.file_num) {
            self.digest = FileDigest::default();
            self.digest_file_num = None;
        }
        self.file_digests.remove(&self.file_num);
        if self.write_content_hash_file_num == Some(self.file_num) {
            self.write_content_hasher = None;
            self.write_content_hash_file_num = None;
            self.write_content_hash_bytes = 0;
        }
        self.clear_pending_conflict(self.file_num);
        self.data_stream.take();
        self.set_file_confirmed(false);
        self.set_file_is_waiting(false);
        self.file_num += 1;
        self.file_skipped = true;
        true
    }

    async fn set_stream_offset(&mut self, file_num: usize, offset: u64) -> ResultType<()> {
        if file_num >= self.files.len() {
            bail!("invalid file number");
        }
        if let DataSource::FilePath(p) = &self.data_source {
            let entry = &self.files[file_num];
            let Some(path) = self.resolve_entry_path(p, &entry.name) else {
                bail!("invalid destination path");
            };
            let file_path = get_string(&path);
            let download_path = format!("{}.download", &file_path);
            let digest_path = format!("{}.digest", &file_path);

            let mut f = match self.direction {
                TransferDirection::Write => {
                    let partial_exists = Path::new(&download_path).exists();
                    let digest_exists = Path::new(&digest_path).exists();
                    if !partial_exists || !digest_exists {
                        bail!("validated partial transfer artifacts are required for resume");
                    }
                    let (digest, ownership) =
                        self.validate_partial_ownership(file_num as i32, false)?;
                    let std_file = std::fs::OpenOptions::new()
                        .write(true)
                        .open(&download_path)?;
                    let metadata = std_file.metadata()?;
                    if !metadata.is_file() {
                        bail!("partial artifact is not a regular file");
                    }
                    let identity = file_identity(&std_file)?;
                    if identity.storage != ownership.partial_storage
                        || identity.file != ownership.partial_file
                    {
                        bail!("partial artifact identity changed");
                    }
                    if offset == 0 || offset != metadata.len() || offset > ownership.source_size {
                        bail!(
                            "resume offset {} does not match the validated partial size {}",
                            offset,
                            metadata.len()
                        );
                    }
                    self.active_partial_token = Some((file_num as i32, ownership.token));
                    // A resumed transfer already has a prefix on disk that was
                    // not observed by this job instance. Keep the streaming
                    // hasher disabled so finalization falls back to a complete
                    // byte-for-byte hash of the owned partial.
                    self.write_content_hasher = None;
                    self.write_content_hash_file_num = None;
                    self.write_content_hash_bytes = 0;
                    self.digest = digest;
                    self.digest_file_num = Some(file_num as i32);
                    self.file_digests
                        .insert(file_num as i32, self.digest.clone());
                    File::from_std(std_file)
                }
                TransferDirection::Read => {
                    if !Path::new(&file_path).exists() {
                        bail!(
                            "file {} not found, cannot seek to offset {}",
                            file_path,
                            offset
                        );
                    }
                    let snapshot = self
                        .source_digest_snapshot
                        .filter(|snapshot| snapshot.file_num == file_num as i32)
                        .ok_or_else(|| anyhow!("resume source digest snapshot is unavailable"))?;
                    let std_file = std::fs::OpenOptions::new().read(true).open(&file_path)?;
                    let metadata = std_file.metadata()?;
                    if !metadata.is_file() {
                        bail!("resume source is not a regular file");
                    }
                    let modified = metadata.modified()?.duration_since(UNIX_EPOCH)?.as_secs();
                    if file_identity(&std_file)? != snapshot.identity
                        || metadata.len() != snapshot.size
                        || modified != snapshot.modified
                    {
                        bail!("source changed since transfer digest was prepared");
                    }
                    if offset > metadata.len() {
                        bail!(
                            "resume offset {} exceeds source size {}",
                            offset,
                            metadata.len()
                        );
                    }
                    File::from_std(std_file)
                }
            };
            f.seek(std::io::SeekFrom::Start(offset)).await?;
            self.data_stream = Some(DataStream::FileStream(f));
            self.transferred += offset;
            self.finished_size += offset;
            Ok(())
        } else {
            bail!("resume offset requires a filesystem-backed transfer")
        }
    }

    pub async fn confirm(&mut self, r: &FileTransferSendConfirmRequest) -> ResultType<()> {
        if self.file_num() != r.file_num {
            // This branch will always be hit if:
            // 1. `confirm()` is called in `ui_cm_interface.rs`
            // 2. Not resuming
            //
            // It is ok. Because `confirm()` in `ui_cm_interface.rs` is only used for resuming.
            log::info!("file num truncated, ignoring");
        } else {
            match r.union {
                Some(file_transfer_send_confirm_request::Union::Skip(s)) => {
                    if s {
                        self.set_file_skipped();
                    } else {
                        self.set_file_confirmed(true);
                    }
                }
                Some(file_transfer_send_confirm_request::Union::OffsetBlk(offset)) => {
                    // If offset is greater than 0, we need to seek to the offset
                    if offset > 0 {
                        if let Err(err) = self
                            .set_stream_offset(r.file_num as usize, offset as u64)
                            .await
                        {
                            log::warn!(
                                "Rejected resume offset for job {}, file {}: {}",
                                self.id,
                                r.file_num,
                                err
                            );
                            return Err(err);
                        }
                        self.clear_pending_conflict(r.file_num);
                    } else if self
                        .pending_conflict
                        .as_ref()
                        .map(|snapshot| snapshot.file_num == r.file_num)
                        .unwrap_or(false)
                    {
                        self.validate_pending_conflict_token(r.file_num, &r.conflict_token)?;
                    }
                    self.set_file_confirmed(true);
                }
                Some(file_transfer_send_confirm_request::Union::KeepBoth(keep_both)) => {
                    if keep_both {
                        self.clear_pending_conflict(r.file_num);
                        self.set_file_confirmed(true);
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    #[inline]
    pub fn gen_meta(&self) -> TransferJobMeta {
        TransferJobMeta {
            id: self.id,
            remote: self.remote.to_string(),
            to: self.data_source.to_meta(),
            file_num: self.file_num,
            show_hidden: self.show_hidden,
            is_remote: self.is_remote,
            ownership_token: self.ownership_token.clone(),
        }
    }
}

#[inline]
pub fn new_error<T: std::string::ToString>(id: i32, err: T, file_num: i32) -> Message {
    let mut resp = FileResponse::new();
    resp.set_error(FileTransferError {
        id,
        error: err.to_string(),
        file_num,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_dir(id: i32, path: String, files: Vec<FileEntry>) -> Message {
    let mut resp = FileResponse::new();
    resp.set_dir(FileDirectory {
        id,
        path,
        entries: files,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_block(block: FileTransferBlock) -> Message {
    let mut resp = FileResponse::new();
    resp.set_block(block);
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_send_confirm(r: FileTransferSendConfirmRequest) -> Message {
    let mut msg_out = Message::new();
    let mut action = FileAction::new();
    action.set_send_confirm(r);
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_receive(
    id: i32,
    path: String,
    file_num: i32,
    files: Vec<FileEntry>,
    total_size: u64,
    ownership_token: String,
) -> Message {
    let mut action = FileAction::new();
    action.set_receive(FileTransferReceiveRequest {
        id,
        path,
        files,
        file_num,
        total_size,
        ownership_token,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_send(
    id: i32,
    r#type: JobType,
    path: String,
    file_num: i32,
    include_hidden: bool,
) -> Message {
    log::info!("new send: {}, id: {}", path, id);
    let mut action = FileAction::new();
    let t: file_transfer_send_request::FileType = r#type.into();
    action.set_send(FileTransferSendRequest {
        id,
        path,
        include_hidden,
        file_num,
        file_type: t.into(),
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_done(id: i32, file_num: i32) -> Message {
    let mut resp = FileResponse::new();
    resp.set_done(FileTransferDone {
        id,
        file_num,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn remove_job(id: i32, jobs: &mut Vec<TransferJob>) -> Option<TransferJob> {
    jobs.iter()
        .position(|x| x.id() == id)
        .map(|index| jobs.remove(index))
}

#[inline]
pub fn get_job(id: i32, jobs: &mut [TransferJob]) -> Option<&mut TransferJob> {
    jobs.iter_mut().find(|x| x.id() == id)
}

#[inline]
pub fn get_job_immutable(id: i32, jobs: &[TransferJob]) -> Option<&TransferJob> {
    jobs.iter().find(|x| x.id() == id)
}

async fn init_jobs(jobs: &mut Vec<TransferJob>, stream: &mut hbb_common::Stream) -> ResultType<()> {
    for job in jobs.iter_mut() {
        if job.is_last_job {
            continue;
        }
        if let Err(err) = job.init_data_stream(stream).await {
            stream
                .send(&new_error(job.id(), err, job.file_num()))
                .await?;
        }
    }
    Ok(())
}

pub async fn handle_read_jobs(
    jobs: &mut Vec<TransferJob>,
    stream: &mut hbb_common::Stream,
) -> ResultType<String> {
    init_jobs(jobs, stream).await?;

    let mut job_log = Default::default();
    let mut finished = Vec::new();
    for job in jobs.iter_mut() {
        if job.is_last_job {
            continue;
        }
        match job.read().await {
            Err(err) => {
                stream
                    .send(&new_error(job.id(), err, job.file_num()))
                    .await?;
            }
            Ok(Some(block)) => {
                stream.send(&new_block(block)).await?;
            }
            Ok(None) => {
                if job.job_completed() {
                    job_log = serialize_transfer_job(job, true, false, "");
                    finished.push(job.id());
                    match job.job_error() {
                        Some(err) => {
                            job_log = serialize_transfer_job(job, false, false, &err);
                            stream
                                .send(&new_error(job.id(), err, job.file_num()))
                                .await?
                        }
                        None => stream.send(&new_done(job.id(), job.file_num())).await?,
                    }
                } else {
                    // waiting confirmation.
                }
            }
        }
        // Break to handle jobs one by one.
        break;
    }
    for id in finished {
        let _ = remove_job(id, jobs);
    }
    Ok(job_log)
}

pub fn remove_all_empty_dir(path: &Path) -> ResultType<()> {
    let fd = read_dir(path, true)?;
    for entry in fd.entries.iter() {
        match entry.entry_type.enum_value() {
            Ok(FileType::Dir) => {
                remove_all_empty_dir(&path.join(&entry.name)).ok();
            }
            Ok(FileType::DirLink) | Ok(FileType::FileLink) => {
                std::fs::remove_file(path.join(&entry.name)).ok();
            }
            _ => {}
        }
    }
    std::fs::remove_dir(path).ok();
    Ok(())
}

#[inline]
pub fn remove_file(file: &str) -> ResultType<()> {
    validate_fs_path_argument(file, "file path")?;
    std::fs::remove_file(get_path(file))?;
    Ok(())
}

#[inline]
pub fn create_dir(dir: &str) -> ResultType<()> {
    validate_fs_path_argument(dir, "directory path")?;
    std::fs::create_dir_all(get_path(dir))?;
    Ok(())
}

#[inline]
pub fn rename_file(path: &str, new_name: &str) -> ResultType<()> {
    validate_fs_path_argument(path, "path")?;
    if new_name.is_empty() {
        bail!("new file name cannot be empty");
    }
    validate_file_name_no_traversal(new_name)?;
    let path = std::path::Path::new(&path);
    if path.exists() {
        let dir = path
            .parent()
            .ok_or(anyhow!("Parent directoy of {path:?} not exists"))?;
        let new_path = dir.join(&new_name);
        std::fs::rename(&path, &new_path)?;
        Ok(())
    } else {
        bail!("{path:?} not exists");
    }
}

#[inline]
pub fn transform_windows_path(entries: &mut Vec<FileEntry>) {
    for entry in entries {
        entry.name = entry.name.replace('\\', "/");
    }
}

pub enum DigestCheckResult {
    IsSame,
    NeedConfirm(FileTransferDigest),
    NoSuchFile,
}

#[inline]
pub fn is_write_need_confirmation(
    job: &TransferJob,
    is_resume: bool,
    file_path: &str,
    digest: &FileTransferDigest,
) -> ResultType<DigestCheckResult> {
    let path = Path::new(file_path);
    let digest_file = format!("{}.digest", file_path);
    let download_file = format!("{}.download", file_path);
    if is_resume && Path::new(&digest_file).exists() && Path::new(&download_file).exists() {
        let (local_digest, _) = job
            .validate_partial_ownership(digest.file_num, false)
            .map_err(|err| anyhow!("existing partial cannot be resumed safely: {err}"))?;
        let has_strong_identity =
            local_digest.content_sha256.len() == 32 && digest.content_sha256.len() == 32;
        let is_identical = local_digest.modified == digest.last_modified
            && local_digest.size == digest.file_size
            && has_strong_identity
            && local_digest.content_sha256 == digest.content_sha256;
        if is_identical {
            let download_metadata = std::fs::metadata(&download_file)?;
            let transferred_size = download_metadata.len();
            if transferred_size > 0 && transferred_size <= digest.file_size {
                return Ok(DigestCheckResult::NeedConfirm(FileTransferDigest {
                    id: digest.id,
                    file_num: digest.file_num,
                    last_modified: digest.last_modified,
                    file_size: digest.file_size,
                    is_identical,
                    transferred_size,
                    ..Default::default()
                }));
            }
        }
    }
    if Path::new(&digest_file).exists() || Path::new(&download_file).exists() {
        bail!("partial transfer artifacts already exist and are not safely resumable");
    }

    if path.exists() && path.is_file() {
        let metadata = std::fs::metadata(path)?;
        let modified_time = metadata.modified()?;
        let remote_mt = Duration::from_secs(digest.last_modified);
        let local_mt = modified_time.duration_since(UNIX_EPOCH)?;
        // [Note]
        // We decide to give the decision whether to override the existing file to users,
        // which obey the behavior of the file manager in our system.
        let mut is_identical = false;
        if remote_mt == local_mt && digest.file_size == metadata.len() {
            is_identical = true;
        }
        Ok(DigestCheckResult::NeedConfirm(FileTransferDigest {
            id: digest.id,
            file_num: digest.file_num,
            last_modified: local_mt.as_secs(),
            file_size: metadata.len(),
            is_identical,
            ..Default::default()
        }))
    } else {
        // If the file does not exist, or the digest file and download file do not exist, we return NoSuchFile.
        Ok(DigestCheckResult::NoSuchFile)
    }
}

pub fn serialize_transfer_jobs(jobs: &[TransferJob]) -> String {
    let mut v = vec![];
    for job in jobs {
        let value = serde_json::to_value(job).unwrap_or_default();
        v.push(value);
    }
    serde_json::to_string(&v).unwrap_or_default()
}

pub fn serialize_transfer_job(job: &TransferJob, done: bool, cancel: bool, error: &str) -> String {
    let mut value = serde_json::to_value(job).unwrap_or_default();
    value["done"] = json!(done);
    value["cancel"] = json!(cancel);
    value["error"] = json!(error);
    serde_json::to_string(&value).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestTempDir {
        path: PathBuf,
    }

    impl TestTempDir {
        fn new(prefix: &str) -> Self {
            Self {
                path: unique_temp_dir(prefix),
            }
        }

        fn join(&self, path: &str) -> PathBuf {
            self.path.join(path)
        }
    }

    impl Drop for TestTempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn unique_temp_dir(prefix: &str) -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("{}_{}_{}", prefix, std::process::id(), timestamp))
    }

    fn new_file_entry(name: &str) -> FileEntry {
        let mut entry = FileEntry::new();
        entry.name = name.to_string();
        entry
    }

    fn new_validation_job(id: i32) -> TransferJob {
        TransferJob::new_write(
            id,
            JobType::Generic,
            "/fake/remote".to_string(),
            DataSource::FilePath(std::env::temp_dir().join(format!("rustdesk_validation_{id}"))),
            0,
            false,
            true,
            false,
        )
    }

    fn new_write_job(id: i32, download_dir: PathBuf, name: &str) -> ResultType<TransferJob> {
        let job = TransferJob::new_write(
            id,
            JobType::Generic,
            "/fake/remote".to_string(),
            DataSource::FilePath(download_dir),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![new_file_entry(name)])?;
        Ok(job)
    }

    fn assert_err_contains(err: anyhow::Error, expected: &str) {
        assert!(
            err.to_string().contains(expected),
            "expected error containing '{}', got: {}",
            expected,
            err
        );
    }

    async fn write_owned_partial(
        job: &mut TransferJob,
        file_num: i32,
        data: &[u8],
    ) -> ResultType<()> {
        job.write(FileTransferBlock {
            id: job.id,
            file_num,
            data: data.to_vec().into(),
            ..Default::default()
        })
        .await?;
        job.sync_partial_for_pause().await
    }

    #[tokio::test]
    async fn resume_validates_source_identity_before_reusing_partial_offset() {
        let tmp_root = TestTempDir::new("rustdesk_resume_identity");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "résumé_日本.dat";
        let target = tmp_root.join(file_name);
        let target_text = target.to_string_lossy().to_string();
        let partial = format!("{}.download", target_text);
        let digest_path = format!("{}.digest", target_text);
        let mut entry = new_file_entry(file_name);
        entry.size = 100;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            1,
            JobType::Generic,
            "/fake/remote".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        let source_hash = vec![0x11; 32];
        job.set_digest_with_hash(0, 100, 1234, source_hash.clone());
        write_owned_partial(&mut job, 0, b"partial")
            .await
            .expect("create owned partial");

        let matching = FileTransferDigest {
            id: 1,
            file_num: 0,
            file_size: 100,
            last_modified: 1234,
            content_sha256: source_hash.into(),
            ..Default::default()
        };
        match is_write_need_confirmation(&job, true, &target_text, &matching)
            .expect("matching resume check")
        {
            DigestCheckResult::NeedConfirm(digest) => {
                assert!(digest.is_identical);
                assert_eq!(digest.transferred_size, 7);
            }
            _ => panic!("matching source identity must expose its safe resume offset"),
        }

        let changed = FileTransferDigest {
            file_size: 101,
            last_modified: 1235,
            ..matching
        };
        job.set_digest_with_hash(
            0,
            changed.file_size,
            changed.last_modified,
            changed.content_sha256.to_vec(),
        );
        let err = match is_write_need_confirmation(&job, true, &target_text, &changed) {
            Err(err) => err,
            Ok(_) => panic!("changed source identity must reject the existing partial"),
        };
        assert_err_contains(err, "existing partial cannot be resumed safely");
        assert!(
            Path::new(&partial).exists(),
            "rejected partial must be preserved"
        );
        assert!(
            Path::new(&digest_path).exists(),
            "sidecar must be preserved"
        );
    }

    #[tokio::test]
    async fn resume_rejects_same_metadata_with_different_source_content_hash() {
        let tmp_root = TestTempDir::new("rustdesk_resume_content_identity");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "same-metadata.bin";
        let target = tmp_root.join(file_name);
        let target_text = target.to_string_lossy().to_string();
        let partial = format!("{}.download", target_text);
        let digest_path = format!("{}.digest", target_text);
        let mut entry = new_file_entry(file_name);
        entry.size = 100;
        entry.modified_time = 1234;
        let original_hash = vec![0x22; 32];
        let mut job = TransferJob::new_write(
            74,
            JobType::Generic,
            "/fake/remote".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest_with_hash(0, 100, 1234, original_hash);
        write_owned_partial(&mut job, 0, b"partial")
            .await
            .expect("create owned partial");

        let replacement_hash = vec![0x33; 32];
        job.set_digest_with_hash(0, 100, 1234, replacement_hash.clone());
        let replacement = FileTransferDigest {
            id: 74,
            file_num: 0,
            file_size: 100,
            last_modified: 1234,
            content_sha256: replacement_hash.into(),
            ..Default::default()
        };
        let err = match is_write_need_confirmation(&job, true, &target_text, &replacement) {
            Err(err) => err,
            Ok(_) => panic!("same metadata with different content must not resume"),
        };
        assert_err_contains(err, "existing partial cannot be resumed safely");
        assert!(
            Path::new(&partial).exists(),
            "rejected partial must be preserved"
        );
        assert!(
            Path::new(&digest_path).exists(),
            "sidecar must be preserved"
        );
    }

    #[tokio::test]
    async fn source_digest_hashes_the_active_source_file() {
        let tmp_root = TestTempDir::new("rustdesk_source_content_digest");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let content = b"content identity survives metadata collisions";
        let source = tmp_root.join("source.bin");
        std::fs::write(&source, content).expect("seed source file");
        let mut entry = new_file_entry("source.bin");
        entry.size = content.len() as u64;

        let mut job = TransferJob::new_read(
            75,
            JobType::Generic,
            "/remote/source.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            false,
            true,
        )
        .expect("valid read job")
        .with_files(vec![entry])
        .expect("valid file list");

        assert!(!job.open_data_stream().await.expect("open source stream"));
        let (_, size, hash) = job.get_current_digest().await.expect("source digest");
        assert_eq!(size, content.len() as u64);
        assert_eq!(hash, Sha256::digest(content).to_vec());
    }

    #[tokio::test]
    async fn read_resume_rejects_source_replaced_after_digest_preparation() {
        let tmp_root = TestTempDir::new("rustdesk_resume_source_swap");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let source = tmp_root.join("source.bin");
        let original = b"abcdef";
        std::fs::write(&source, original).expect("seed source file");
        let mut entry = new_file_entry("source.bin");
        entry.size = original.len() as u64;

        let mut job = TransferJob::new_read(
            77,
            JobType::Generic,
            "/remote/source.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            false,
            true,
        )
        .expect("valid read job")
        .with_files(vec![entry])
        .expect("valid file list");
        job.is_resume = true;

        let digest = loop {
            if let Some(digest) = job
                .init_data_stream_for_cm()
                .await
                .expect("prepare source digest")
            {
                break digest;
            }
            hbb_common::tokio::task::yield_now().await;
        };
        assert_eq!(digest.1, original.len() as u64);

        let original_path = tmp_root.join("source.original.bin");
        std::fs::rename(&source, &original_path).expect("move hashed source aside");
        std::fs::write(&source, b"ghijkl").expect("replace source with same-size file");

        let request = FileTransferSendConfirmRequest {
            id: 77,
            file_num: 0,
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(3)),
            ..Default::default()
        };
        let err = job
            .confirm(&request)
            .await
            .expect_err("resume must reject a source path that changed after hashing");
        assert_err_contains(err, "source changed since transfer digest was prepared");
    }

    #[tokio::test]
    async fn cm_digest_preparation_returns_before_background_hash_finishes() {
        let tmp_root = TestTempDir::new("rustdesk_background_content_digest");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let content = vec![0x5au8; 2 * 1024 * 1024];
        let source = tmp_root.join("source.bin");
        std::fs::write(&source, &content).expect("seed source file");
        let mut entry = new_file_entry("source.bin");
        entry.size = content.len() as u64;

        let mut job = TransferJob::new_read(
            76,
            JobType::Generic,
            "/remote/source.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            false,
            true,
        )
        .expect("valid read job")
        .with_files(vec![entry])
        .expect("valid file list");

        let first = job
            .init_data_stream_for_cm()
            .await
            .expect("start background digest");
        assert!(
            first.is_none(),
            "the transfer tick must not wait for the whole-file hash"
        );
        assert!(
            job.file_is_waiting(),
            "hash preparation keeps the job pending"
        );

        for _ in 0..10_000 {
            if let Some((_, size, hash)) = job
                .init_data_stream_for_cm()
                .await
                .expect("poll background digest")
            {
                assert_eq!(size, content.len() as u64);
                assert_eq!(hash, Sha256::digest(&content).to_vec());
                return;
            }
            hbb_common::tokio::task::yield_now().await;
        }

        panic!("background digest did not complete");
    }

    #[tokio::test]
    async fn restored_job_uses_persisted_ownership_token_after_job_id_changes() {
        let tmp_root = TestTempDir::new("rustdesk_resume_persisted_owner");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("resume.bin");
        entry.size = 7;
        entry.modified_time = 1234;
        let mut original = TransferJob::new_write(
            70,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry.clone()])
        .expect("valid original job");
        original.set_digest(0, 7, 1234);
        write_owned_partial(&mut original, 0, b"partial")
            .await
            .expect("create owned partial");
        let saved = original.gen_meta();
        assert!(!saved.ownership_token.is_empty());
        drop(original);

        let mut restored = TransferJob::new_write(
            71,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid restored job");
        restored.set_digest(0, 7, 1234);
        restored
            .restore_ownership_token(&saved.ownership_token)
            .expect("persisted ownership token should be valid");

        restored
            .set_stream_offset(0, 7)
            .await
            .expect("restored job should reclaim its own partial");
    }

    #[tokio::test]
    async fn restored_job_rejects_matching_partial_without_persisted_ownership_token() {
        let tmp_root = TestTempDir::new("rustdesk_resume_missing_owner");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("resume.bin");
        entry.size = 7;
        entry.modified_time = 1234;
        let mut original = TransferJob::new_write(
            72,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry.clone()])
        .expect("valid original job");
        original.set_digest(0, 7, 1234);
        write_owned_partial(&mut original, 0, b"partial")
            .await
            .expect("create owned partial");
        drop(original);

        let mut unrelated = TransferJob::new_write(
            73,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid unrelated job");
        unrelated.set_digest(0, 7, 1234);

        let err = unrelated
            .set_stream_offset(0, 7)
            .await
            .expect_err("matching metadata alone must not claim another job's partial");
        assert_err_contains(err, "partial ownership does not match this transfer");
    }

    #[test]
    fn digest_identity_is_scoped_to_the_matching_file() {
        let tmp_root = TestTempDir::new("rustdesk_digest_file_scope");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut first = new_file_entry("first.bin");
        first.size = 10;
        first.modified_time = 100;
        let mut second = new_file_entry("second.bin");
        second.size = 20;
        second.modified_time = 200;
        let mut job = TransferJob::new_write(
            74,
            JobType::Generic,
            "/remote/files".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![first, second])
        .expect("valid multi-file job");

        job.set_digest(0, 11, 111);

        assert_eq!(
            job.source_identity_for_file(0).expect("first identity"),
            (11, 111)
        );
        assert_eq!(
            job.source_identity_for_file(1).expect("second identity"),
            (20, 200),
            "digest metadata from file 0 must not leak into file 1"
        );
    }

    #[tokio::test]
    async fn finalization_rejects_missing_owned_partial() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_missing_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("missing.bin");
        entry.size = 1;
        let mut job = TransferJob::new_write(
            75,
            JobType::Generic,
            "/remote/missing.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");

        let err = job
            .modify_time()
            .await
            .expect_err("a Done message must not succeed without an owned partial");
        assert_err_contains(err, "no owned partial to finalize");
        assert!(!tmp_root.join("missing.bin").exists());
    }

    #[tokio::test]
    async fn confirm_propagates_rejected_resume_error() {
        let tmp_root = TestTempDir::new("rustdesk_confirm_resume_error");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("resume.bin");
        entry.size = 7;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            76,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest(0, 7, 1234);
        write_owned_partial(&mut job, 0, b"partial")
            .await
            .expect("create owned partial");

        let partial_path = tmp_root.join("resume.bin.download");
        let original_path = tmp_root.join("resume.bin.download.original");
        std::fs::rename(&partial_path, &original_path).expect("move original partial aside");
        std::fs::write(&partial_path, b"swapped").expect("replace partial path");

        let request = FileTransferSendConfirmRequest {
            id: 76,
            file_num: 0,
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(7)),
            ..Default::default()
        };
        let err = job
            .confirm(&request)
            .await
            .expect_err("invalid resume confirmation must propagate an error");
        assert_err_contains(err, "partial artifact identity changed");
        assert!(!job.file_confirmed());
    }

    #[tokio::test]
    async fn resume_rejects_partial_larger_than_source() {
        let tmp_root = TestTempDir::new("rustdesk_resume_oversized_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "source.bin";
        let target = tmp_root.join(file_name);
        let target_text = target.to_string_lossy().to_string();
        let mut entry = new_file_entry(file_name);
        entry.size = 100;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            2,
            JobType::Generic,
            "/fake/remote".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest(0, 100, 1234);
        write_owned_partial(&mut job, 0, b"partial")
            .await
            .expect("create owned partial");
        std::fs::write(format!("{}.download", target_text), vec![1u8; 101])
            .expect("grow partial past source size");

        let source = FileTransferDigest {
            id: 2,
            file_num: 0,
            file_size: 100,
            last_modified: 1234,
            ..Default::default()
        };
        let err = match is_write_need_confirmation(&job, true, &target_text, &source) {
            Err(err) => err,
            Ok(_) => panic!("oversized partial must not be resumable"),
        };
        assert_err_contains(err, "not safely resumable");
    }

    #[tokio::test]
    async fn cancel_cleans_only_owned_partial_artifacts() {
        let tmp_root = TestTempDir::new("rustdesk_cancel_owned_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("owned.txt");
        entry.size = 5;
        let mut job = TransferJob::new_write(
            55,
            JobType::Generic,
            "/remote/owned.txt".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        let final_path = tmp_root.join("owned.txt");
        let partial_path = tmp_root.join("owned.txt.download");
        let digest_path = tmp_root.join("owned.txt.digest");
        let unrelated_path = tmp_root.join("other.download");
        std::fs::write(&final_path, b"keep").expect("write final file");
        write_owned_partial(&mut job, 0, b"owned")
            .await
            .expect("create owned partial");
        std::fs::write(&unrelated_path, b"unrelated").expect("write unrelated");

        job.remove_download_file();

        assert!(final_path.exists(), "completed destination must remain");
        assert!(!partial_path.exists(), "owned partial should be removed");
        assert!(!digest_path.exists(), "owned digest should be removed");
        assert!(unrelated_path.exists(), "unrelated partial must remain");
    }

    #[tokio::test]
    async fn cancel_preserves_swapped_partial_artifact() {
        let tmp_root = TestTempDir::new("rustdesk_cancel_swapped_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("owned.txt");
        entry.size = 5;
        let mut job = TransferJob::new_write(
            59,
            JobType::Generic,
            "/remote/owned.txt".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        write_owned_partial(&mut job, 0, b"owned")
            .await
            .expect("create owned partial");

        let partial_path = tmp_root.join("owned.txt.download");
        let original_path = tmp_root.join("owned.txt.download.original");
        let digest_path = tmp_root.join("owned.txt.digest");
        std::fs::rename(&partial_path, &original_path).expect("move original partial aside");
        std::fs::write(&partial_path, b"user replacement").expect("write replacement partial");

        job.remove_download_file();

        assert_eq!(
            std::fs::read(&partial_path).expect("read replacement"),
            b"user replacement"
        );
        assert!(
            digest_path.exists(),
            "sidecar must remain when identity changed"
        );
        assert!(
            original_path.exists(),
            "original owned partial remains available"
        );
    }

    #[tokio::test]
    async fn printer_write_reuses_existing_spool_path() {
        let tmp_root = TestTempDir::new("rustdesk_printer_existing_spool");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let spool = tmp_root.join("print-job.bin");
        std::fs::write(&spool, b"old").expect("seed spool path");
        let mut entry = new_file_entry("");
        entry.size = 3;
        let mut job = TransferJob::new_write(
            60,
            JobType::Printer,
            String::new(),
            DataSource::FilePath(spool.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![entry])
        .expect("valid printer job");

        job.write(FileTransferBlock {
            id: 60,
            file_num: 0,
            data: b"new".to_vec().into(),
            ..Default::default()
        })
        .await
        .expect("printer write should truncate the existing spool file");
        job.sync_partial_for_pause()
            .await
            .expect("flush printer spool");

        assert_eq!(std::fs::read(spool).expect("read spool"), b"new");
    }

    #[tokio::test]
    async fn first_write_does_not_mutate_existing_conflict_snapshot() {
        let tmp_root = TestTempDir::new("rustdesk_first_write_conflict_snapshot");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "conflict.txt";
        let final_path = tmp_root.join(file_name);
        std::fs::write(&final_path, b"existing").expect("seed destination");
        let mut entry = new_file_entry(file_name);
        entry.size = 5;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            61,
            JobType::Generic,
            "/remote/conflict.txt".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.capture_pending_conflict(0, &final_path)
            .expect("capture destination conflict");

        job.write(FileTransferBlock {
            id: 61,
            file_num: 0,
            data: b"new!!".to_vec().into(),
            ..Default::default()
        })
        .await
        .expect("open first partial");

        job.validate_pending_conflict(0)
            .expect("opening the first partial must not mutate the existing destination");
        assert_eq!(
            std::fs::read(final_path).expect("read destination"),
            b"existing"
        );
    }

    #[tokio::test]
    async fn resume_seek_rejects_swapped_partial_identity() {
        let tmp_root = TestTempDir::new("rustdesk_resume_swapped_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("resume.bin");
        entry.size = 7;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            62,
            JobType::Generic,
            "/remote/resume.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest(0, 7, 1234);
        write_owned_partial(&mut job, 0, b"partial")
            .await
            .expect("create owned partial");

        let partial_path = tmp_root.join("resume.bin.download");
        let original_path = tmp_root.join("resume.bin.download.original");
        std::fs::rename(&partial_path, &original_path).expect("move original partial aside");
        std::fs::write(&partial_path, b"swapped").expect("replace partial path");

        let err = job
            .set_stream_offset(0, 7)
            .await
            .expect_err("swapped partial must be rejected");
        assert_err_contains(err, "partial artifact identity changed");

        assert!(
            job.data_stream.is_none(),
            "a swapped partial must never become the active resume stream"
        );
    }

    #[tokio::test]
    async fn incomplete_partial_is_not_finalized() {
        let tmp_root = TestTempDir::new("rustdesk_incomplete_finalization");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let mut entry = new_file_entry("large.bin");
        entry.size = 10;
        let mut job = TransferJob::new_write(
            63,
            JobType::Generic,
            "/remote/large.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        write_owned_partial(&mut job, 0, b"short")
            .await
            .expect("create incomplete partial");

        let err = job
            .modify_time()
            .await
            .expect_err("incomplete partial must not finalize");
        assert_err_contains(err, "partial transfer is incomplete");

        assert!(
            !tmp_root.join("large.bin").exists(),
            "incomplete data must not publish"
        );
        assert!(
            tmp_root.join("large.bin.download").exists(),
            "partial must remain"
        );
        assert!(
            tmp_root.join("large.bin.digest").exists(),
            "sidecar must remain"
        );
    }

    #[tokio::test]
    async fn changed_destination_is_not_replaced_during_finalization() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_changed_destination");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "replace.txt";
        let final_path = tmp_root.join(file_name);
        std::fs::write(&final_path, b"original").expect("seed destination");
        let mut entry = new_file_entry(file_name);
        entry.size = 5;
        let mut job = TransferJob::new_write(
            64,
            JobType::Generic,
            "/remote/replace.txt".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.capture_pending_conflict(0, &final_path)
            .expect("capture replace conflict");
        write_owned_partial(&mut job, 0, b"fresh")
            .await
            .expect("create complete partial");

        std::fs::write(&final_path, b"changed after confirmation")
            .expect("change destination after conflict snapshot");
        let err = job
            .modify_time()
            .await
            .expect_err("changed destination must reject finalization");
        assert_err_contains(err, "destination changed since the conflict prompt");

        assert_eq!(
            std::fs::read(&final_path).expect("read changed destination"),
            b"changed after confirmation"
        );
        assert!(
            tmp_root.join("replace.txt.download").exists(),
            "owned partial must remain for explicit recovery"
        );
        assert!(
            tmp_root.join("replace.txt.digest").exists(),
            "ownership sidecar must remain when finalization is rejected"
        );
    }

    #[tokio::test]
    async fn finalization_rejects_same_size_content_corruption() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_content_hash");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "verified.bin";
        let expected = b"fresh";
        let mut entry = new_file_entry(file_name);
        entry.size = expected.len() as u64;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            66,
            JobType::Generic,
            "/remote/verified.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest_with_hash(
            0,
            expected.len() as u64,
            1234,
            Sha256::digest(expected).to_vec(),
        );
        write_owned_partial(&mut job, 0, b"wrong")
            .await
            .expect("create same-size corrupted partial");

        let err = job
            .modify_time()
            .await
            .expect_err("content mismatch must reject finalization");
        assert_err_contains(err, "content hash");
        assert!(!tmp_root.join(file_name).exists());
        assert!(tmp_root.join("verified.bin.download").exists());
        assert!(tmp_root.join("verified.bin.digest").exists());
    }

    #[tokio::test]
    async fn fresh_strong_hash_finalization_verifies_the_partial_on_disk() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_streamed_hash");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "streamed.bin";
        let expected = vec![0x5au8; 2 * 1024 * 1024];
        let mut entry = new_file_entry(file_name);
        entry.size = expected.len() as u64;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            67,
            JobType::Generic,
            "/remote/streamed.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest_with_hash(
            0,
            expected.len() as u64,
            1234,
            Sha256::digest(&expected).to_vec(),
        );
        write_owned_partial(&mut job, 0, &expected)
            .await
            .expect("create complete owned partial");

        job.modify_time().await.expect("finalize streamed transfer");

        assert_eq!(job.final_hash_rescan_count, 1);
        assert_eq!(
            std::fs::read(tmp_root.join(file_name)).expect("read published file"),
            expected
        );
    }

    #[tokio::test]
    async fn fresh_finalization_rejects_partial_changed_after_streamed_write() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_post_write_mutation");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "mutated.bin";
        let expected = b"fresh";
        let mut entry = new_file_entry(file_name);
        entry.size = expected.len() as u64;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            68,
            JobType::Generic,
            "/remote/mutated.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.set_digest_with_hash(
            0,
            expected.len() as u64,
            1234,
            Sha256::digest(expected).to_vec(),
        );
        write_owned_partial(&mut job, 0, expected)
            .await
            .expect("create complete owned partial");
        std::fs::write(tmp_root.join("mutated.bin.download"), b"wrong")
            .expect("mutate partial after streamed write");

        let err = job
            .modify_time()
            .await
            .expect_err("on-disk mutation must reject finalization");
        assert_err_contains(err, "content hash");
        assert!(!tmp_root.join(file_name).exists());
        assert!(tmp_root.join("mutated.bin.download").exists());
    }

    #[tokio::test]
    async fn next_file_digest_does_not_break_previous_file_finalization() {
        let tmp_root = TestTempDir::new("rustdesk_multifile_digest_scope");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let first_data = b"first";
        let second_data = b"second";
        let mut first = new_file_entry("first.bin");
        first.size = first_data.len() as u64;
        first.modified_time = 111;
        let mut second = new_file_entry("second.bin");
        second.size = second_data.len() as u64;
        second.modified_time = 222;
        let mut job = TransferJob::new_write(
            68,
            JobType::Generic,
            "/remote/files".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![first, second])
        .expect("valid multi-file write job");

        job.set_digest_with_hash(
            0,
            first_data.len() as u64,
            111,
            Sha256::digest(first_data).to_vec(),
        );
        job.write(FileTransferBlock {
            id: 68,
            file_num: 0,
            data: first_data.to_vec().into(),
            ..Default::default()
        })
        .await
        .expect("write first file");

        // The sender prepares the next file's digest before its first data
        // block arrives. Finalizing file 0 must still use file 0's ownership
        // record rather than the now-current digest for file 1.
        job.set_digest_with_hash(
            1,
            second_data.len() as u64,
            222,
            Sha256::digest(second_data).to_vec(),
        );
        job.write(FileTransferBlock {
            id: 68,
            file_num: 1,
            data: second_data.to_vec().into(),
            ..Default::default()
        })
        .await
        .expect("transition to second file");

        assert_eq!(
            std::fs::read(tmp_root.join("first.bin")).expect("read first published file"),
            first_data
        );
        job.sync_partial_for_pause()
            .await
            .expect("flush second file");
        job.modify_time().await.expect("finalize second file");
        assert_eq!(
            std::fs::read(tmp_root.join("second.bin")).expect("read second published file"),
            second_data
        );
    }

    #[tokio::test]
    async fn zero_byte_digest_overrides_stale_file_list_size() {
        let tmp_root = TestTempDir::new("rustdesk_zero_byte_digest");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "empty.bin";
        let mut entry = new_file_entry(file_name);
        entry.size = 99;
        entry.modified_time = 999;
        let mut job = TransferJob::new_write(
            69,
            JobType::Generic,
            "/remote/empty.bin".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid zero-byte write job");
        job.set_digest_with_hash(0, 0, 1234, Sha256::digest([]).to_vec());

        job.write(FileTransferBlock {
            id: 69,
            file_num: 0,
            data: Vec::<u8>::new().into(),
            ..Default::default()
        })
        .await
        .expect("create zero-byte partial");
        job.sync_partial_for_pause()
            .await
            .expect("flush zero-byte partial");
        job.modify_time().await.expect("finalize zero-byte file");

        assert_eq!(
            std::fs::metadata(tmp_root.join(file_name))
                .expect("zero-byte destination exists")
                .len(),
            0
        );
    }

    #[tokio::test]
    async fn confirmed_destination_is_replaced_without_leaving_backup_artifacts() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_confirmed_destination");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "replace.txt";
        let final_path = tmp_root.join(file_name);
        std::fs::write(&final_path, b"original").expect("seed destination");
        let mut entry = new_file_entry(file_name);
        entry.size = 5;
        entry.modified_time = 1234;
        let mut job = TransferJob::new_write(
            65,
            JobType::Generic,
            "/remote/replace.txt".to_owned(),
            DataSource::FilePath(tmp_root.path.clone()),
            0,
            false,
            true,
            true,
        )
        .with_files(vec![entry])
        .expect("valid write job");
        job.capture_pending_conflict(0, &final_path)
            .expect("capture replace conflict");
        write_owned_partial(&mut job, 0, b"fresh")
            .await
            .expect("create complete partial");

        job.modify_time()
            .await
            .expect("confirmed destination should publish");

        assert_eq!(
            std::fs::read(&final_path).expect("read destination"),
            b"fresh"
        );
        assert!(!tmp_root.join("replace.txt.download").exists());
        assert!(!tmp_root.join("replace.txt.digest").exists());
        assert!(
            !tmp_root.join("replace (1).txt").exists(),
            "temporary replacement backup should be removed after publish"
        );
    }

    #[test]
    fn publish_failure_restores_previous_destination_from_backup() {
        let tmp_root = TestTempDir::new("rustdesk_finalize_publish_rollback");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let final_path = tmp_root.join("replace.txt");
        let backup_path = tmp_root.join("replace (1).txt");
        std::fs::write(&backup_path, b"original").expect("seed moved backup");

        let err = publish_with_rollback(&final_path, Some(&backup_path), || {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "simulated publish failure",
            ))
        })
        .expect_err("publish failure must be reported");

        assert_err_contains(err, "simulated publish failure");
        assert_eq!(
            std::fs::read(&final_path).expect("read restored file"),
            b"original"
        );
        assert!(
            !backup_path.exists(),
            "rollback should restore the original path"
        );
    }

    #[test]
    fn cancel_preserves_unmarked_partial_artifacts() {
        let tmp_root = TestTempDir::new("rustdesk_cancel_unowned_partial");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let job = new_write_job(57, tmp_root.path.clone(), "user.txt").expect("valid write job");
        let partial_path = tmp_root.join("user.txt.download");
        let digest_path = tmp_root.join("user.txt.digest");
        std::fs::write(&partial_path, b"user data").expect("write user partial");
        std::fs::write(&digest_path, r#"{"size":9,"modified":1}"#).expect("write legacy sidecar");

        job.remove_download_file();

        assert!(partial_path.exists(), "unmarked partial must be preserved");
        assert!(digest_path.exists(), "unmarked sidecar must be preserved");
    }

    #[test]
    fn replace_requires_matching_conflict_snapshot() {
        let tmp_root = TestTempDir::new("rustdesk_conflict_snapshot");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "conflict.txt";
        let target = tmp_root.join(file_name);
        std::fs::write(&target, b"first version").expect("write original destination");
        let mut job = new_write_job(58, tmp_root.path.clone(), file_name).expect("valid write job");
        job.capture_pending_conflict(0, &target)
            .expect("capture conflict snapshot");
        job.validate_pending_conflict(0)
            .expect("unchanged destination remains valid");

        std::fs::remove_file(&target).expect("replace destination");
        std::fs::write(&target, b"second version").expect("write replacement destination");

        let err = job
            .validate_pending_conflict(0)
            .expect_err("stale replace decision must be rejected");
        assert_err_contains(err, "destination changed since the conflict prompt");
    }

    #[tokio::test]
    async fn replace_rejects_a_stale_conflict_token() {
        let tmp_root = TestTempDir::new("rustdesk_conflict_token");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "conflict.txt";
        let target = tmp_root.join(file_name);
        std::fs::write(&target, b"existing destination").expect("write destination");
        let mut job = new_write_job(59, tmp_root.path.clone(), file_name).expect("valid write job");
        job.capture_pending_conflict(0, &target)
            .expect("capture conflict snapshot");

        let req = FileTransferSendConfirmRequest {
            id: 59,
            file_num: 0,
            conflict_token: "stale-conflict-token".to_owned(),
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
            ..Default::default()
        };
        let err = job
            .confirm(&req)
            .await
            .expect_err("stale conflict decision must be rejected");
        assert_err_contains(err, "conflict token");
        assert!(!job.file_confirmed());
    }

    #[test]
    fn keep_both_uses_unique_unicode_sibling_without_overwrite() {
        let tmp_root = TestTempDir::new("rustdesk_keep_both");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        let file_name = "résumé_日本.txt";
        let job =
            new_write_job(56, tmp_root.path.clone(), file_name).expect("valid keep-both write job");
        let original = tmp_root.join(file_name);
        let occupied = tmp_root.join("résumé_日本 (1).txt");
        let partial = tmp_root.join("résumé_日本.txt.download");
        std::fs::write(&original, b"original").expect("write original");
        std::fs::write(&occupied, b"occupied").expect("write occupied sibling");
        std::fs::write(&partial, b"partial").expect("write transfer partial");

        let kept = job
            .keep_both_existing_destination(0)
            .expect("keep both succeeds")
            .expect("existing destination was moved");

        assert_eq!(kept, tmp_root.join("résumé_日本 (2).txt"));
        assert_eq!(std::fs::read(&kept).expect("read kept file"), b"original");
        assert_eq!(
            std::fs::read(&occupied).expect("read occupied sibling"),
            b"occupied"
        );
        assert_eq!(std::fs::read(&partial).expect("read partial"), b"partial");
        assert!(!original.exists());
    }

    #[test]
    fn path_traversal_e2e_write_rejects_relative_escape() {
        let tmp_root = TestTempDir::new("rustdesk_e2e_relative");
        let downloads = tmp_root.join("downloads");
        std::fs::create_dir_all(&downloads).expect("create downloads dir");

        let err = new_write_job(1, downloads, "../traversal_proof.txt")
            .expect_err("relative path traversal must be rejected");
        assert_err_contains(err, "path traversal");
        assert!(!tmp_root.join("traversal_proof.txt").exists());
    }

    #[test]
    fn path_traversal_e2e_write_rejects_absolute_path() {
        let tmp_root = TestTempDir::new("rustdesk_e2e_absolute");
        let downloads = tmp_root.join("downloads");
        let absolute_target = tmp_root.join("fake_ssh").join("authorized_keys");
        std::fs::create_dir_all(&downloads).expect("create downloads dir");

        let err = new_write_job(2, downloads, &absolute_target.to_string_lossy())
            .expect_err("absolute path must be rejected");
        assert_err_contains(err, "absolute path");
        assert!(!absolute_target.exists());
    }

    #[test]
    #[cfg_attr(windows, ignore = "requires symlink privilege to create test symlink")]
    fn path_traversal_e2e_write_rejects_symlink_escape() {
        let tmp_root = TestTempDir::new("rustdesk_e2e_symlink");
        let downloads = tmp_root.join("downloads");
        let outside = tmp_root.join("outside");
        let escaped_target = outside.join("escape.txt");
        std::fs::create_dir_all(&downloads).expect("create downloads dir");
        std::fs::create_dir_all(&outside).expect("create outside dir");

        let symlink_path = downloads.join("link");
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            symlink(&outside, &symlink_path).expect("create symlink for test");
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::symlink_dir;
            symlink_dir(&outside, &symlink_path).expect("create directory symlink for test");
        }

        let err = new_write_job(3, downloads, "link/escape.txt")
            .expect_err("symlink traversal must be rejected");
        assert_err_contains(err, "symlink");
        assert!(!escaped_target.exists());
    }

    #[test]
    fn set_files_allows_single_empty_name_for_single_file_transfer() {
        let mut job = new_validation_job(101);
        assert!(job.set_files(vec![new_file_entry("")]).is_ok());
    }

    #[test]
    fn set_files_rejects_empty_name_in_multi_file_transfer() {
        let mut job = new_validation_job(102);
        let err = job
            .set_files(vec![new_file_entry(""), new_file_entry("ok.txt")])
            .expect_err("empty name in multi-file transfer must be rejected");
        assert_err_contains(err, "empty file name");
    }

    #[test]
    fn set_files_rejects_null_byte_name() {
        let mut job = new_validation_job(103);
        let err = job
            .set_files(vec![new_file_entry("bad\0name.txt")])
            .expect_err("null byte in file name must be rejected");
        assert_err_contains(err, "null bytes");
    }

    #[test]
    fn set_files_rejects_mixed_entries_when_one_is_traversal() {
        let mut job = new_validation_job(104);
        let err = job
            .set_files(vec![
                new_file_entry("safe/file.txt"),
                new_file_entry("../../escape.txt"),
            ])
            .expect_err("any traversal entry must reject the full file list");
        assert_err_contains(err, "path traversal");
    }

    #[cfg(windows)]
    #[test]
    fn set_files_rejects_unc_absolute_path() {
        let mut job = new_validation_job(105);
        let err = job
            .set_files(vec![new_file_entry("\\\\server\\share\\payload.txt")])
            .expect_err("UNC absolute path must be rejected");
        assert_err_contains(err, "absolute path");
    }

    #[cfg(not(windows))]
    #[test]
    fn set_files_allows_backslash_prefixed_name_on_unix() {
        let mut job = new_validation_job(105);
        assert!(job
            .set_files(vec![new_file_entry("\\\\server\\share\\payload.txt")])
            .is_ok());
    }

    #[test]
    fn remove_file_rejects_empty_path() {
        let err = remove_file("").expect_err("empty file path must be rejected");
        assert_err_contains(err, "cannot be empty");
    }

    #[test]
    fn remove_file_rejects_null_byte_path() {
        let err = remove_file("bad\0path").expect_err("null byte path must be rejected");
        assert_err_contains(err, "null bytes");
    }

    #[test]
    fn create_dir_rejects_empty_path() {
        let err = create_dir("").expect_err("empty directory path must be rejected");
        assert_err_contains(err, "cannot be empty");
    }

    #[test]
    fn create_dir_rejects_null_byte_path() {
        let err = create_dir("bad\0path").expect_err("null byte path must be rejected");
        assert_err_contains(err, "null bytes");
    }

    #[test]
    fn rename_file_rejects_invalid_new_name() {
        let tmp_root = TestTempDir::new("rustdesk_rename_invalid");
        let src = tmp_root.join("source.txt");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        std::fs::write(&src, b"content").expect("create source file");

        let src_str = src.to_string_lossy().to_string();

        let err_empty =
            rename_file(&src_str, "").expect_err("empty new file name must be rejected");
        assert_err_contains(err_empty, "cannot be empty");

        let err_traversal = rename_file(&src_str, "../escape.txt")
            .expect_err("traversal new file name must be rejected");
        assert_err_contains(err_traversal, "path traversal");

        let err_null = rename_file(&src_str, "bad\0name.txt")
            .expect_err("null byte in new file name must be rejected");
        assert_err_contains(err_null, "null bytes");

        #[cfg(windows)]
        {
            let err_abs = rename_file(&src_str, "C:\\Windows\\Temp\\payload.txt")
                .expect_err("absolute new file name must be rejected");
            assert_err_contains(err_abs, "absolute path");
        }
        #[cfg(not(windows))]
        {
            let err_abs = rename_file(&src_str, "/tmp/payload.txt")
                .expect_err("absolute new file name must be rejected");
            assert_err_contains(err_abs, "absolute path");
        }
    }

    #[test]
    fn rename_file_accepts_valid_new_name() {
        let tmp_root = TestTempDir::new("rustdesk_rename_ok");
        let src = tmp_root.join("rename_src.txt");
        let dst = tmp_root.join("renamed.txt");
        std::fs::create_dir_all(&tmp_root.path).expect("create temp dir");
        std::fs::write(&src, b"content").expect("create source file");

        let src_str = src.to_string_lossy().to_string();
        rename_file(&src_str, "renamed.txt").expect("rename should succeed");

        assert!(!src.exists());
        assert!(dst.exists());
    }

    #[cfg(windows)]
    #[test]
    fn set_files_rejects_windows_drive_absolute_path() {
        let mut job = new_validation_job(106);
        let err = job
            .set_files(vec![new_file_entry("C:\\Windows\\Temp\\payload.txt")])
            .expect_err("drive-letter absolute path must be rejected");
        assert_err_contains(err, "absolute path");
    }

    #[cfg(windows)]
    #[test]
    fn set_files_rejects_windows_verbatim_drive_absolute_path() {
        let mut job = new_validation_job(1061);
        let err = job
            .set_files(vec![new_file_entry(r"\\?\C:\Windows\Temp\x.txt")])
            .expect_err("verbatim drive absolute path must be rejected");
        assert_err_contains(err, "absolute path");
    }
}
