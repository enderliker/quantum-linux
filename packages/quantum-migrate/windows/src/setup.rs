//! Lo que hace el instalador en Windows: revisar el PC, preparar el pendrive, descargar Quantum,
//! achicar Windows, pedir la llave de arranque seguro y dejar el PC listo para arrancar del pendrive.
//! En Linux (solo para desarrollar la interfaz) todo se simula.

use serde_json::Value;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub const GB: u64 = 1_000_000_000;
pub const MIN_QUANTUM: u64 = 30 * GB;          // menos que esto no alcanza para usar Quantum con comodidad
pub const MIN_USB: u64 = 8 * GB;
pub const LATEST: &str = "https://quantumlinux-arch.github.io/descargas/latest.json";
pub const SHIM_GUID: &str = "{605dab50-e046-4300-abb6-3dd810dd8b23}";
pub const EFI_GLOBAL: &str = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}";
pub const QUANTUM_CER: &[u8] = include_bytes!("../../../quantum-secureboot/files/quantum-sb.cer");

#[derive(Clone, Debug, Default)]
pub struct Disk {
    pub number: u32,
    pub name: String,
    pub size: u64,
    pub serial: String,
    pub system: bool,     // tiene Windows (C:)
    pub usb: bool,
    pub gpt: bool,
}

#[derive(Clone, Debug, Default)]
pub struct PcInfo {
    pub uefi: bool,
    pub secureboot: bool,
    pub bitlocker: bool,
    pub disks: Vec<Disk>,
    pub c_free: u64,          // espacio libre en C:
    pub c_shrinkable: u64,    // cuánto se puede achicar C: como máximo
    pub unallocated: u64,     // espacio sin usar que ya tiene el disco de Windows
    pub ram: u64,
}

impl PcInfo {
    /// «Junto a Windows»: si el disco ya tiene espacio sin usar, ese; si no, la mitad del espacio
    /// libre de C: (sin pasar de lo que Windows deja achicar).
    pub fn beside_size(&self) -> u64 {
        if self.uses_unallocated() { return self.unallocated / GB * GB; }
        (self.c_free / 2).min(self.c_shrinkable.saturating_sub(GB)) / GB * GB
    }
    pub fn uses_unallocated(&self) -> bool { self.unallocated >= MIN_QUANTUM }
    /// Hay espacio libre de sobra, pero Windows no deja achicar el disco lo suficiente
    pub fn shrink_limited(&self) -> bool { self.c_free / 2 >= MIN_QUANTUM && self.beside_size() < MIN_QUANTUM }
    pub fn system_disk(&self) -> Option<&Disk> { self.disks.iter().find(|d| d.system) }
}

#[derive(Clone, Debug)]
pub struct Latest { pub version: String, pub url: String, pub sha256: String, pub size: u64 }

// ===================================================================== Windows
#[cfg(windows)]
mod imp {
    use super::*;
    use std::os::windows::process::CommandExt;
    const NO_WINDOW: u32 = 0x0800_0000;

    /// Ejecuta PowerShell sin ventana; devuelve la salida o el error.
    pub fn ps(script: &str) -> Result<String, String> {
        ps_env(script, &[])
    }

    pub fn ps_env(script: &str, envs: &[(&str, &str)]) -> Result<String, String> {
        log(&format!("ps: {}", script.lines().map(str::trim).collect::<Vec<_>>().join(" ").chars().take(160).collect::<String>()));
        let mut cmd = std::process::Command::new("powershell");
        cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
                   &format!("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; try {{ {script} }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}")]);
        for (k, v) in envs {
            cmd.env(k, v);
        }
        let out = cmd.creation_flags(NO_WINDOW).output().map_err(|e| e.to_string())?;
        if out.status.success() { Ok(String::from_utf8_lossy(&out.stdout).trim().to_string()) }
        else { Err(String::from_utf8_lossy(&out.stderr).trim().lines().next().unwrap_or("error").to_string()) }
    }

    fn json(script: &str) -> Value {
        ps(&format!("{script} | ConvertTo-Json -Depth 4 -Compress")).ok()
            .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
    }
    fn list(v: Value) -> Vec<Value> { match v { Value::Array(a) => a, Value::Null => vec![], x => vec![x] } }

    pub fn pc_info() -> PcInfo {
        let mut i = PcInfo::default();
        let mut ft = 0i32;
        unsafe { windows_sys::Win32::System::SystemInformation::GetFirmwareType(&mut ft as *mut i32 as _); }
        i.uefi = ft == 2; // FirmwareTypeUefi
        // todo en una sola llamada: PowerShell tarda en arrancar
        let v = json(r#"$c = Get-Partition -DriveLetter C
            $sb = $false; try { $sb = Confirm-SecureBootUEFI } catch {}
            $bl = $false; try { $bl = (Get-BitLockerVolume -MountPoint C:).ProtectionStatus -eq 'On' } catch {}
            $min = $c.Size; try { $min = (Get-PartitionSupportedSize -DriveLetter C).SizeMin } catch {}
            [pscustomobject]@{
              sb = $sb; bl = $bl; sys = $c.DiskNumber; size = $c.Size; min = $min
              free = (Get-Volume -DriveLetter C).SizeRemaining
              unalloc = (Get-Disk -Number $c.DiskNumber).LargestFreeExtent
              ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
              disks = @(Get-Disk | Select Number,FriendlyName,Size,SerialNumber,@{n='Bus';e={"$($_.BusType)"}},@{n='Style';e={"$($_.PartitionStyle)"}})
            }"#);
        let n = |k: &str| v[k].as_u64().unwrap_or(0);
        i.secureboot = v["sb"].as_bool().unwrap_or(false);
        i.bitlocker = v["bl"].as_bool().unwrap_or(false);
        i.c_free = n("free");
        i.c_shrinkable = n("size").saturating_sub(n("min"));
        i.unallocated = n("unalloc");
        i.ram = n("ram");
        let sysnum = v["sys"].as_u64();
        for d in list(v["disks"].clone()) {
            let num = d["Number"].as_u64().unwrap_or(0);
            i.disks.push(Disk {
                number: num as u32, name: d["FriendlyName"].as_str().unwrap_or("").trim().to_string(),
                size: d["Size"].as_u64().unwrap_or(0), serial: d["SerialNumber"].as_str().unwrap_or("").trim().to_string(),
                system: Some(num) == sysnum, usb: d["Bus"].as_str() == Some("USB"), gpt: d["Style"].as_str() == Some("GPT"),
            });
        }
        log(&format!("pc: {i:?}"));
        i
    }

    /// Borra el pendrive y crea QUANTUMINST (FAT32, para arrancar) y QUANTUMDATA (exFAT, tus cosas).
    /// Devuelve las letras de las dos particiones.
    pub fn prepare_usb(d: &Disk) -> Result<(String, Option<String>), String> {
        // seguro: solo discos USB que no tengan Windows
        let chk = ps(&format!("$d=Get-Disk -Number {}; \"$($d.BusType)|$($d.IsBoot)|$($d.IsSystem)|$($d.Size)\"", d.number))?;
        let p: Vec<&str> = chk.split('|').collect();
        if p.len() < 4 || p[0] != "USB" || p[1] == "True" || p[2] == "True" || p[3].parse::<u64>().ok() != Some(d.size) {
            return Err("Por seguridad no toqué ese disco: no parece ser el pendrive elegido".into());
        }
        let boot = 7_500u64; // MB
        let data = d.size / 1_000_000 > boot + 1_200;
        // diskpart maneja mejor los pendrives que los comandos de PowerShell
        let mut dp = format!("select disk {}\nclean\nconvert gpt\ncreate partition primary size={boot}\nformat fs=fat32 quick label=QUANTUMINST\nassign\n", d.number);
        if data { dp += "create partition primary\nformat fs=exfat quick label=QUANTUMDATA\nassign\n"; }
        let f = std::env::temp_dir().join("quantum-diskpart.txt");
        std::fs::write(&f, dp).map_err(|e| e.to_string())?;
        let out = std::process::Command::new("diskpart").args(["/s", &f.to_string_lossy()]).creation_flags(NO_WINDOW).output().map_err(|e| e.to_string())?;
        log(&format!("diskpart: {}", String::from_utf8_lossy(&out.stdout).lines().filter(|l| !l.trim().is_empty()).last().unwrap_or("")));
        std::thread::sleep(std::time::Duration::from_secs(3));
        let r = ps(&format!(r#"$v = Get-Partition -DiskNumber {} | Get-Volume
            $a = ($v | ? FileSystemLabel -eq 'QUANTUMINST' | ? FileSystem -eq 'FAT32').DriveLetter
            $b = ($v | ? FileSystemLabel -eq 'QUANTUMDATA').DriveLetter
            "$a|$b""#, d.number))?;
        let mut it = r.lines().last().unwrap_or("").split('|');
        let a = it.next().unwrap_or("").to_string();
        let b = it.next().unwrap_or("").to_string();
        if a.is_empty() { return Err("No se pudo preparar el pendrive. Prueba con otro o en otro puerto USB.".into()); }
        Ok((format!("{a}:\\"), if b.is_empty() { None } else { Some(format!("{b}:\\")) }))
    }

    pub fn mount_iso(iso: &Path) -> Result<PathBuf, String> {
        let iso_str = iso.to_string_lossy();
        let l = ps_env(
            "(Mount-DiskImage -ImagePath $env:QUANTUM_ISO -PassThru | Get-Volume).DriveLetter",
            &[("QUANTUM_ISO", &iso_str)],
        )?;
        Ok(PathBuf::from(format!("{}:\\", l.trim())))
    }
    pub fn unmount_iso(iso: &Path) {
        let iso_str = iso.to_string_lossy();
        let _ = ps_env(
            "Dismount-DiskImage -ImagePath $env:QUANTUM_ISO | Out-Null",
            &[("QUANTUM_ISO", &iso_str)],
        );
    }

    /// Llave propia de este PC para el arranque seguro (se crea en Windows y Quantum la usa después).
    pub fn machine_key(dir: &Path, computer: &str) -> Result<Vec<u8>, String> {
        let pfx = dir.join("MOK.pfx");
        let cer = dir.join("MOK.cer");
        let pfx_str = pfx.to_string_lossy();
        let cer_str = cer.to_string_lossy();
        let safe_computer = computer.replace(['\r', '\n', ',', '=', ';', '\''], "");
        ps_env(r#"
            $subj = "CN=Quantum Linux - " + $env:QUANTUM_COMP + ", O=Quantum Linux"
            $c = New-SelfSignedCertificate -Subject $subj -Type CodeSigningCert `
                 -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -HashAlgorithm SHA256 `
                 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(20)
            $pw = ConvertTo-SecureString -String 'quantum' -Force -AsPlainText
            Export-PfxCertificate -Cert $c -FilePath $env:QUANTUM_PFX -Password $pw | Out-Null
            Export-Certificate -Cert $c -FilePath $env:QUANTUM_CER -Type CERT | Out-Null
            Remove-Item "Cert:\CurrentUser\My\$($c.Thumbprint)"
        "#, &[
            ("QUANTUM_COMP", &safe_computer),
            ("QUANTUM_PFX", &pfx_str),
            ("QUANTUM_CER", &cer_str),
        ])?;
        std::fs::read(&cer).map_err(|e| e.to_string())
    }

    /// Hace que Windows deje achicar más el disco: apaga la hibernación (su archivo no se puede
    /// mover) y junta el espacio libre al principio del disco (desfragmentar «consolidando»).
    pub fn make_room() -> Result<(), String> {
        let _ = ps("powercfg /h off");
        ps("defrag C: /X /U | Out-Null").map(|_| ())
    }

    pub fn suspend_bitlocker() -> Result<(), String> {
        ps("Suspend-BitLocker -MountPoint C: -RebootCount 3 | Out-Null").map(|_| ())
    }

    /// Achica C: para dejar `bytes` libres al final del disco.
    pub fn shrink_c(bytes: u64) -> Result<(), String> {
        let bytes_str = bytes.to_string();
        ps_env(
            "$p=Get-Partition -DriveLetter C; $s=[uint64]$env:QUANTUM_SHRINK; Resize-Partition -DriveLetter C -Size ($p.Size - $s)",
            &[("QUANTUM_SHRINK", &bytes_str)],
        ).map(|_| ())
    }

    fn privilege() {
        let _ = ps("");
        // SeSystemEnvironmentPrivilege: necesario para escribir variables del firmware
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::Security::*;
        use windows_sys::Win32::System::Threading::*;
        unsafe {
            let mut tok: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut tok) == 0 { return; }
            let name: Vec<u16> = "SeSystemEnvironmentPrivilege\0".encode_utf16().collect();
            let mut tp: TOKEN_PRIVILEGES = std::mem::zeroed();
            tp.PrivilegeCount = 1;
            if LookupPrivilegeValueW(std::ptr::null(), name.as_ptr(), &mut tp.Privileges[0].Luid) != 0 {
                tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
                AdjustTokenPrivileges(tok, 0, &tp, 0, std::ptr::null_mut(), std::ptr::null_mut());
            }
            CloseHandle(tok);
        }
    }

    fn w(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }

    pub fn set_var(name: &str, guid: &str, data: &[u8], attrs: u32) -> Result<(), String> {
        privilege();
        use windows_sys::Win32::System::WindowsProgramming::SetFirmwareEnvironmentVariableExW;
        let ok = unsafe { SetFirmwareEnvironmentVariableExW(w(name).as_ptr(), w(guid).as_ptr(), data.as_ptr() as _, data.len() as u32, attrs) };
        if ok == 0 { Err(format!("No pude escribir {name} en el firmware ({})", std::io::Error::last_os_error())) } else { Ok(()) }
    }

    pub fn get_var(name: &str, guid: &str) -> Option<Vec<u8>> {
        privilege();
        use windows_sys::Win32::System::WindowsProgramming::GetFirmwareEnvironmentVariableExW;
        let mut buf = vec![0u8; 32768]; let mut attrs = 0u32;
        let n = unsafe { GetFirmwareEnvironmentVariableExW(w(name).as_ptr(), w(guid).as_ptr(), buf.as_mut_ptr() as _, buf.len() as u32, &mut attrs) };
        (n > 0).then(|| { buf.truncate(n as usize); buf })
    }

    /// Partición QUANTUMINST: (número, inicio en sectores, tamaño en sectores, GUID de la partición)
    pub fn usb_partition(letter: &str) -> Result<(u32, u64, u64, String), String> {
        let l = letter.trim_end_matches(['\\', ':']);
        if l.len() != 1 || !l.chars().next().unwrap().is_ascii_alphabetic() {
            return Err("Letra de unidad inválida".into());
        }
        let r = ps_env(
            r#"$p=Get-Partition -DriveLetter $env:QUANTUM_DRIVE; $s=(Get-Disk -Number $p.DiskNumber).LogicalSectorSize; "$($p.PartitionNumber)|$($p.Offset/$s)|$($p.Size/$s)|$($p.Guid)""#,
            &[("QUANTUM_DRIVE", l)],
        )?;
        let p: Vec<&str> = r.split('|').collect();
        if p.len() < 4 { return Err("No pude leer la partición del pendrive".into()); }
        Ok((p[0].parse().unwrap_or(1), p[1].parse().unwrap_or(0), p[2].parse().unwrap_or(0), p[3].trim_matches(['{', '}']).to_string()))
    }

    pub fn reboot() { let _ = std::process::Command::new("shutdown").args(["/r", "/t", "3"]).creation_flags(NO_WINDOW).spawn(); }
}

// ======================================================= Linux (para desarrollar)
#[cfg(not(windows))]
mod imp {
    use super::*;
    pub fn ps(_s: &str) -> Result<String, String> { Ok(String::new()) }
    pub fn ps_env(_s: &str, _envs: &[(&str, &str)]) -> Result<String, String> { Ok(String::new()) }
    pub fn pc_info() -> PcInfo {
        std::thread::sleep(std::time::Duration::from_millis(600));
        PcInfo { uefi: true, secureboot: true, bitlocker: false, c_free: 180 * GB, c_shrinkable: std::env::var("PAQ_SHRINK_GB").ok().and_then(|v| v.parse().ok()).unwrap_or(200) * GB, ram: 16 * GB, unallocated: 0,
            disks: vec![
                Disk { number: 0, name: "Samsung SSD 970 EVO".into(), size: 512 * GB, serial: "S4EVNX0N".into(), system: true, usb: false, gpt: true },
                Disk { number: 1, name: "Kingston DataTraveler".into(), size: 32 * GB, serial: "".into(), system: false, usb: true, gpt: false },
            ] }
    }
    fn fake() -> PathBuf { PathBuf::from(std::env::var("PAQ_FAKE_USB").unwrap_or("/tmp/paq-usb".into())) }
    pub fn prepare_usb(_d: &Disk) -> Result<(String, Option<String>), String> {
        std::thread::sleep(std::time::Duration::from_secs(2));
        let a = fake().join("QUANTUMINST"); let b = fake().join("QUANTUMDATA");
        let _ = std::fs::create_dir_all(&a); let _ = std::fs::create_dir_all(&b);
        Ok((a.to_string_lossy().to_string(), Some(b.to_string_lossy().to_string())))
    }
    pub fn mount_iso(_iso: &Path) -> Result<PathBuf, String> {
        Ok(PathBuf::from(std::env::var("PAQ_FAKE_ISO_DIR").unwrap_or("/tmp/paq-iso".into())))
    }
    pub fn unmount_iso(_iso: &Path) {}
    pub fn machine_key(dir: &Path, _c: &str) -> Result<Vec<u8>, String> { let _ = std::fs::write(dir.join("MOK.cer"), b"x"); Ok(b"x".to_vec()) }
    pub fn suspend_bitlocker() -> Result<(), String> { Ok(()) }
    pub fn make_room() -> Result<(), String> { std::thread::sleep(std::time::Duration::from_secs(4)); Ok(()) }
    pub fn shrink_c(_b: u64) -> Result<(), String> { std::thread::sleep(std::time::Duration::from_secs(3)); Ok(()) }
    pub fn set_var(_n: &str, _g: &str, _d: &[u8], _a: u32) -> Result<(), String> { Ok(()) }
    pub fn get_var(_n: &str, _g: &str) -> Option<Vec<u8>> { None }
    pub fn usb_partition(_l: &str) -> Result<(u32, u64, u64, String), String> { Ok((1, 2048, 15_000_000, "8f9a6a3e-0000-4000-8000-000000000001".into())) }
    pub fn reboot() {}
}

pub use imp::*;

// ============================================================ común

/// Registro para diagnosticar fallos: %TEMP%\instalar-quantum.log
pub fn log(msg: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(std::env::temp_dir().join("instalar-quantum.log")) {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(f, "[{t}] {msg}");
    }
}

/// Lee latest.json (versión, enlace, SHA256 y tamaño del ISO más nuevo).
pub fn latest() -> Result<Latest, String> {
    let url = std::env::var("QUANTUM_LATEST").unwrap_or(LATEST.into());
    let v: Value = ureq::get(&url).timeout(std::time::Duration::from_secs(20)).call().map_err(|e| e.to_string())?
        .into_json().map_err(|e| e.to_string())?;
    Ok(Latest { version: v["version"].as_str().unwrap_or("").into(), url: v["url"].as_str().unwrap_or("").into(),
                sha256: v["sha256"].as_str().unwrap_or("").to_lowercase(), size: v["size"].as_u64().unwrap_or(0) })
}

/// Descarga el ISO (sigue si quedó a medias) verificando el SHA256. `prog(hecho, total)`.
pub fn download(l: &Latest, dst: &Path, cancel: &std::sync::atomic::AtomicBool, prog: &dyn Fn(u64, u64), status: &dyn Fn(&str)) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    use std::sync::atomic::Ordering;
    if let Some(p) = dst.parent() { let _ = std::fs::create_dir_all(p); }
    let mut have = std::fs::metadata(dst).map(|m| m.len()).unwrap_or(0);
    let resumed = have > 0;
    let mut hasher = Sha256::new();
    if have > 0 {
        // lo ya descargado entra al cálculo del SHA256
        let mut f = std::fs::File::open(dst).map_err(|e| e.to_string())?;
        let mut buf = vec![0u8; 1 << 20];
        let mut done = 0u64;
        loop {
            let n = f.read(&mut buf).map_err(|e| e.to_string())?; if n == 0 { break; }
            hasher.update(&buf[..n]); done += n as u64;
            if done % (64 << 20) < n as u64 { status(&format!("Revisando lo que ya se descargó… {} %", (done * 100 / have.max(1)))); }
        }
    }
    if l.size == 0 || have < l.size {
        let agent = ureq::AgentBuilder::new().timeout_connect(std::time::Duration::from_secs(30)).build();
        let mut req = agent.get(&l.url);
        if have > 0 { req = req.set("Range", &format!("bytes={have}-")); }
        let resp = req.call().map_err(|e| format!("No se pudo descargar: {e}"))?;
        if have > 0 && resp.status() != 206 { have = 0; hasher = Sha256::new(); }
        let total = if l.size > 0 { l.size } else { have + resp.header("Content-Length").and_then(|s| s.parse().ok()).unwrap_or(0) };
        let mut out = std::fs::OpenOptions::new().create(true).write(true).append(have > 0).truncate(have == 0).open(dst).map_err(|e| e.to_string())?;
        let mut r = resp.into_reader();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            if cancel.load(Ordering::Relaxed) { return Err("Cancelado".into()); }
            let n = r.read(&mut buf).map_err(|e| format!("Se cortó la descarga: {e}"))?;
            if n == 0 { break; }
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            hasher.update(&buf[..n]);
            have += n as u64;
            prog(have, total);
        }
    }
    let got: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if !l.sha256.is_empty() && got != l.sha256 {
        let _ = std::fs::remove_file(dst);
        // lo que había de antes era de otra versión: se descarga de cero una vez
        if resumed { return download(l, dst, cancel, prog, status); }
        return Err("El archivo descargado está dañado (el SHA256 no coincide). Vuelve a intentarlo.".into());
    }
    Ok(())
}

/// Copia una carpeta completa con avance.
pub fn copy_tree(src: &Path, dst: &Path, prog: &dyn Fn(u64, u64)) -> Result<(), String> {
    let files: Vec<_> = walkdir::WalkDir::new(src).into_iter().flatten().filter(|e| e.file_type().is_file()).collect();
    let total: u64 = files.iter().filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum();
    let mut done = 0u64;
    let mut buf = vec![0u8; 4 << 20];
    for e in files {
        let rel = e.path().strip_prefix(src).unwrap();
        let to = dst.join(rel);
        if let Some(p) = to.parent() { std::fs::create_dir_all(p).map_err(|e| e.to_string())?; }
        let mut i = std::fs::File::open(e.path()).map_err(|e| e.to_string())?;
        let mut o = std::fs::File::create(&to).map_err(|e| format!("{}: {e}", to.display()))?;
        loop {
            let n = i.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 { break; }
            o.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            done += n as u64;
            prog(done, total);
        }
    }
    Ok(())
}

/// Pide registrar las llaves en el próximo arranque (como `mokutil --import`): MokNew + MokAuth.
pub fn request_mok(certs: &[Vec<u8>], password: &str) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    let x509 = guid_bytes("a5c059a1-94e4-4aa7-87b5-ab155c2bf072");
    let owner = guid_bytes("605dab50-e046-4300-abb6-3dd810dd8b23");
    let mut new = vec![];
    for c in certs {
        let size = (16 + c.len()) as u32;
        new.extend_from_slice(&x509);
        new.extend_from_slice(&(28 + size).to_le_bytes());
        new.extend_from_slice(&0u32.to_le_bytes());
        new.extend_from_slice(&size.to_le_bytes());
        new.extend_from_slice(&owner);
        new.extend_from_slice(c);
    }
    let mut h = Sha256::new();
    h.update(&new);
    h.update(password.encode_utf16().flat_map(|u| u.to_le_bytes()).collect::<Vec<u8>>());
    let auth = h.finalize().to_vec();
    log(&format!("MokNew: {} llaves, {} bytes", certs.len(), new.len()));
    set_var("MokNew", SHIM_GUID, &new, 7)?;
    set_var("MokAuth", SHIM_GUID, &auth, 7)?;
    // se comprueba leyendo de vuelta: si el firmware no la guardó, mejor saberlo aquí
    let back = get_var("MokNew", SHIM_GUID).map(|v| v.len()).unwrap_or(0);
    log(&format!("MokNew leída de vuelta: {back} bytes"));
    if back != new.len() { return Err("El firmware no guardó la solicitud de la llave".into()); }
    Ok(())
}

/// Crea una entrada de arranque para el pendrive y la deja como «el próximo arranque» (BootNext).
pub fn boot_next_usb(letter: &str) -> Result<(), String> {
    let (num, start, size, guid) = usb_partition(letter)?;
    let mut hd = vec![4u8, 1, 42, 0];
    hd.extend_from_slice(&num.to_le_bytes());
    hd.extend_from_slice(&start.to_le_bytes());
    hd.extend_from_slice(&size.to_le_bytes());
    hd.extend_from_slice(&guid_bytes(&guid));
    hd.extend_from_slice(&[2, 2]); // GPT, firma = GUID
    let path: Vec<u8> = "\\EFI\\BOOT\\BOOTX64.EFI".encode_utf16().chain(Some(0)).flat_map(|u| u.to_le_bytes()).collect();
    let mut file = vec![4u8, 4];
    file.extend_from_slice(&((4 + path.len()) as u16).to_le_bytes());
    file.extend_from_slice(&path);
    let dp: Vec<u8> = [hd, file, vec![0x7f, 0xff, 4, 0]].concat();
    let desc: Vec<u8> = "Quantum Linux (instalación)".encode_utf16().chain(Some(0)).flat_map(|u| u.to_le_bytes()).collect();
    let mut opt = 1u32.to_le_bytes().to_vec();
    opt.extend_from_slice(&(dp.len() as u16).to_le_bytes());
    opt.extend_from_slice(&desc);
    opt.extend_from_slice(&dp);
    // se reutiliza la entrada de una instalación anterior; si no hay, el primer número libre desde 0x0F00
    let ours = |n: &u16| get_var(&format!("Boot{n:04X}"), EFI_GLOBAL).is_some_and(|v| v.len() > 6 && v[6..].starts_with(&desc[..desc.len() - 2]));
    let n = (0x0F00u16..0x0FFF).find(ours)
        .or_else(|| (0x0F00u16..0x0FFF).find(|n| get_var(&format!("Boot{n:04X}"), EFI_GLOBAL).is_none()))
        .unwrap_or(0x0F00);
    set_var(&format!("Boot{n:04X}"), EFI_GLOBAL, &opt, 7)?;
    set_var("BootNext", EFI_GLOBAL, &n.to_le_bytes(), 7)?;
    // también primera en el orden: tras registrar la llave, MokManager reinicia y BootNext ya se usó.
    // Quantum la borra al terminar de instalarse.
    let old = get_var("BootOrder", EFI_GLOBAL).unwrap_or_default();
    let mut order: Vec<u8> = n.to_le_bytes().to_vec();
    for c in old.chunks_exact(2) { if u16::from_le_bytes([c[0], c[1]]) != n { order.extend_from_slice(c); } }
    log(&format!("BootOrder: Boot{n:04X} primero"));
    set_var("BootOrder", EFI_GLOBAL, &order, 7)
}

pub fn guid_bytes(g: &str) -> [u8; 16] {
    let h: String = g.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    let b: Vec<u8> = (0..16).map(|i| u8::from_str_radix(h.get(i * 2..i * 2 + 2).unwrap_or("00"), 16).unwrap_or(0)).collect();
    // los tres primeros campos van en little endian
    [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]]
}

/// Contraseña cifrada como la guarda Linux (SHA-512 crypt).
pub fn hash_password(pw: &str) -> String {
    let params = sha_crypt::Sha512Params::new(5000).unwrap();
    sha_crypt::sha512_simple(pw, &params).unwrap_or_default()
}

/// Usuario de Linux a partir del nombre: «Juan Pérez» → «juan».
pub fn login_from(name: &str) -> String {
    let first = name.split_whitespace().next().unwrap_or("").to_lowercase();
    let map = |c: char| match c { 'á' | 'à' | 'ä' | 'â' => 'a', 'é' | 'è' | 'ë' | 'ê' => 'e', 'í' | 'ì' | 'ï' | 'î' => 'i',
                                  'ó' | 'ò' | 'ö' | 'ô' => 'o', 'ú' | 'ù' | 'ü' | 'û' => 'u', 'ñ' => 'n', c => c };
    let s: String = first.chars().map(map).filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
    let s = s.trim_start_matches(|c: char| c.is_ascii_digit() || c == '-').to_string();
    if s.is_empty() || s == "root" { "usuario".into() } else { s.chars().take(30).collect() }
}

/// Zona horaria de Windows → Linux (las más comunes; si no está, se deja la de Santiago).
pub fn tz_linux(win: &str) -> &'static str {
    match win {
        "Pacific SA Standard Time" => "America/Santiago", "Argentina Standard Time" => "America/Argentina/Buenos_Aires",
        "SA Pacific Standard Time" => "America/Bogota", "SA Western Standard Time" => "America/La_Paz",
        "Central Standard Time (Mexico)" => "America/Mexico_City", "Venezuela Standard Time" => "America/Caracas",
        "E. South America Standard Time" => "America/Sao_Paulo", "Central America Standard Time" => "America/Guatemala",
        "Romance Standard Time" => "Europe/Madrid", "Paraguay Standard Time" => "America/Asuncion",
        "Montevideo Standard Time" => "America/Montevideo", "Eastern Standard Time" => "America/New_York",
        "Pacific Standard Time" => "America/Los_Angeles", "UTC" => "UTC", _ => "America/Santiago",
    }
}

/// Teclado de Windows (KLID) → distribución de Linux.
pub fn kb_linux(klid: &str) -> &'static str {
    match klid.to_lowercase().as_str() {
        "0000080a" => "latam", "0000040a" | "00000c0a" => "es", "00000416" => "br", "00000809" => "gb", _ => "us",
    }
}
