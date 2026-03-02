use anyhow::Error;
use deno_ast::{
    EmitOptions, MediaType, ParseParams, SourceMapOption, TranspileModuleOptions, TranspileOptions,
};
use deno_core::{
    ModuleLoadResponse, ModuleLoader, ModuleSource, ModuleSourceCode, ModuleSpecifier, ModuleType,
    RequestedModuleType, ResolutionKind,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct CachedModule {
    code: String,
    module_type: ModuleType,
}

pub struct TsModuleLoader {
    /// In-memory cache: URL string → (code, module_type)
    cache: Arc<Mutex<HashMap<String, CachedModule>>>,
    /// Optional on-disk cache directory
    cache_dir: Option<PathBuf>,
}

impl TsModuleLoader {
    pub fn new(cache_dir: Option<String>) -> Self {
        Self {
            cache: Arc::new(Mutex::new(HashMap::new())),
            cache_dir: cache_dir.map(PathBuf::from),
        }
    }

    fn media_type_from_specifier(specifier: &ModuleSpecifier) -> MediaType {
        let path = specifier.path();
        if path.ends_with(".ts") {
            MediaType::TypeScript
        } else if path.ends_with(".tsx") {
            MediaType::Tsx
        } else if path.ends_with(".jsx") {
            MediaType::Jsx
        } else if path.ends_with(".mts") {
            MediaType::Mts
        } else if path.ends_with(".cts") {
            MediaType::Cts
        } else if path.ends_with(".json") {
            MediaType::Json
        } else {
            MediaType::JavaScript
        }
    }

    fn media_type_from_content_type(content_type: &str) -> MediaType {
        let ct = content_type.split(';').next().unwrap_or("").trim();
        match ct {
            "application/typescript" | "text/typescript" => MediaType::TypeScript,
            "application/javascript" | "text/javascript" => MediaType::JavaScript,
            "application/json" | "text/json" => MediaType::Json,
            "text/jsx" => MediaType::Jsx,
            "text/tsx" => MediaType::Tsx,
            _ => MediaType::Unknown,
        }
    }

    fn needs_transpile(media_type: MediaType) -> bool {
        matches!(
            media_type,
            MediaType::TypeScript
                | MediaType::Tsx
                | MediaType::Jsx
                | MediaType::Mts
                | MediaType::Cts
                | MediaType::Dts
        )
    }

    fn transpile_source(
        specifier: &ModuleSpecifier,
        source: &str,
        media_type: MediaType,
    ) -> Result<String, Error> {
        let parsed = deno_ast::parse_module(ParseParams {
            specifier: specifier.clone(),
            text: source.into(),
            media_type,
            capture_tokens: false,
            scope_analysis: false,
            maybe_syntax: None,
        })?;

        let transpiled = parsed.transpile(
            &TranspileOptions::default(),
            &TranspileModuleOptions::default(),
            &EmitOptions {
                source_map: SourceMapOption::None,
                ..Default::default()
            },
        )?;

        Ok(transpiled.into_source().text)
    }

    /// Compute a disk cache file path from a URL using a simple hash
    fn disk_cache_path(&self, url: &str) -> Option<PathBuf> {
        self.cache_dir.as_ref().map(|dir| {
            // Simple hash: replace non-alphanumeric chars with underscores, truncate
            let safe_name: String = url
                .chars()
                .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
                .collect();
            // Truncate to avoid filesystem path length limits
            let name = if safe_name.len() > 200 {
                &safe_name[..200]
            } else {
                &safe_name
            };
            dir.join(name)
        })
    }

    /// Try to read from disk cache
    fn read_disk_cache(&self, url: &str) -> Option<String> {
        let path = self.disk_cache_path(url)?;
        std::fs::read_to_string(path).ok()
    }

    /// Write to disk cache
    fn write_disk_cache(&self, url: &str, content: &str) {
        if let Some(path) = self.disk_cache_path(url) {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(path, content);
        }
    }

    fn load_file(&self, specifier: &ModuleSpecifier) -> Result<ModuleSource, Error> {
        let path = specifier
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("Invalid file URL: {}", specifier))?;

        let source = std::fs::read_to_string(&path)
            .map_err(|e| anyhow::anyhow!("Failed to read {}: {}", path.display(), e))?;

        let media_type = Self::media_type_from_specifier(specifier);
        let module_type = if media_type == MediaType::Json {
            ModuleType::Json
        } else {
            ModuleType::JavaScript
        };

        let code = if Self::needs_transpile(media_type) {
            Self::transpile_source(specifier, &source, media_type)?
        } else {
            source
        };

        Ok(ModuleSource::new(
            module_type,
            ModuleSourceCode::String(code.into()),
            specifier,
            None,
        ))
    }

    fn load_remote(&self, specifier: &ModuleSpecifier) -> Result<ModuleSource, Error> {
        let url_str = specifier.to_string();

        // Check in-memory cache first
        if let Ok(cache) = self.cache.lock() {
            if let Some(cached) = cache.get(&url_str) {
                return Ok(ModuleSource::new(
                    cached.module_type.clone(),
                    ModuleSourceCode::String(cached.code.clone().into()),
                    specifier,
                    None,
                ));
            }
        }

        // Check disk cache
        if let Some(disk_content) = self.read_disk_cache(&url_str) {
            // Determine media type from URL for disk-cached content
            let media_type = Self::media_type_from_specifier(specifier);
            let module_type = if media_type == MediaType::Json {
                ModuleType::Json
            } else {
                ModuleType::JavaScript
            };

            // Store in memory cache too
            if let Ok(mut cache) = self.cache.lock() {
                cache.insert(
                    url_str.clone(),
                    CachedModule {
                        code: disk_content.clone(),
                        module_type: module_type.clone(),
                    },
                );
            }

            return Ok(ModuleSource::new(
                module_type,
                ModuleSourceCode::String(disk_content.into()),
                specifier,
                None,
            ));
        }

        // Fetch from network
        let response = ureq::get(specifier.as_str())
            .call()
            .map_err(|e| anyhow::anyhow!("HTTP fetch error for {}: {}", specifier, e))?;

        // Determine media type from Content-Type header, fall back to URL extension
        let content_type = response
            .header("Content-Type")
            .unwrap_or("")
            .to_string();
        let media_type_from_ct = Self::media_type_from_content_type(&content_type);
        let media_type = if media_type_from_ct == MediaType::Unknown {
            Self::media_type_from_specifier(specifier)
        } else {
            media_type_from_ct
        };

        let module_type = if media_type == MediaType::Json {
            ModuleType::Json
        } else {
            ModuleType::JavaScript
        };

        let source = response
            .into_string()
            .map_err(|e| anyhow::anyhow!("Failed to read response body from {}: {}", specifier, e))?;

        // Transpile if needed
        let code = if Self::needs_transpile(media_type) {
            Self::transpile_source(specifier, &source, media_type)?
        } else {
            source
        };

        // Store in memory cache
        if let Ok(mut cache) = self.cache.lock() {
            cache.insert(
                url_str.clone(),
                CachedModule {
                    code: code.clone(),
                    module_type: module_type.clone(),
                },
            );
        }

        // Store in disk cache
        self.write_disk_cache(&url_str, &code);

        Ok(ModuleSource::new(
            module_type,
            ModuleSourceCode::String(code.into()),
            specifier,
            None,
        ))
    }
}

impl ModuleLoader for TsModuleLoader {
    fn resolve(
        &self,
        specifier: &str,
        referrer: &str,
        _kind: ResolutionKind,
    ) -> Result<ModuleSpecifier, Error> {
        deno_core::resolve_import(specifier, referrer).map_err(|e| e.into())
    }

    fn load(
        &self,
        module_specifier: &ModuleSpecifier,
        _maybe_referrer: Option<&ModuleSpecifier>,
        _is_dyn_import: bool,
        _requested_module_type: RequestedModuleType,
    ) -> ModuleLoadResponse {
        let specifier = module_specifier.clone();

        let result = match specifier.scheme() {
            "file" => self.load_file(&specifier),
            "https" | "http" => self.load_remote(&specifier),
            scheme => Err(anyhow::anyhow!(
                "Unsupported scheme '{}' in module specifier: {}",
                scheme,
                specifier
            )),
        };

        ModuleLoadResponse::Sync(result)
    }
}
