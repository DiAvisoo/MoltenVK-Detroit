/*
 * MVKShaderModule.mm
 *
 * Copyright (c) 2015-2026 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKShaderModule.h"
#include "MVKPipeline.h"
#include "MVKFoundation.h"
#include <sys/stat.h>
#include <condition_variable>
#include <cctype>
#include <cstdarg>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

using namespace std;
using namespace mvk;

#define MVK_DTR_SHADER_LOG_PREFIX "MVK-DTR-BINARY-ARCHIVE: "

static bool mvkDTRBoolEnvValue(const char* name, bool defaultValue) {
	const char* env = getenv(name);
	if ( !env ) { return defaultValue; }
	while (*env == ' ' || *env == '\t' || *env == '\n' || *env == '\r') { env++; }
	if (*env == '0') { return false; }
	if (*env == '1') { return true; }
	return defaultValue;
}

static const char* mvkDTRGetEnv(const char* primaryName, const char* fallbackName = nullptr) {
	const char* env = getenv(primaryName);
	if (env && *env) { return env; }
	return fallbackName ? getenv(fallbackName) : nullptr;
}

static bool mvkDTRShaderCacheLogEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_SHADER_CACHE_LOG", false);
}

static uint64_t mvkDTRShaderSlowCompileThresholdNS() {
	const char* env = getenv("MVK_DTR_SHADER_SLOW_COMPILE_MS");
	double thresholdMS = (env && *env) ? strtod(env, nullptr) : 1000.0;
	return thresholdMS <= 0.0 ? 0 : (uint64_t)(thresholdMS * 1000000.0);
}

static bool mvkDTRShaderResourceLogEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_SHADER_RESOURCE_LOG", false);
}

static bool mvkDTRMSLLibraryCacheEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_MSL_LIBRARY_CACHE", true);
}

static NSString* mvkDTRMSLLibraryDiskCacheDir() {
	const char* env = mvkDTRGetEnv("VK_DTR_MSL_LIBRARY_DISK_CACHE_DIR", "MVK_DTR_MSL_LIBRARY_DISK_CACHE_DIR");
	if (env && *env) { return [[NSString stringWithUTF8String: env] stringByExpandingTildeInPath]; }

	NSArray<NSString*>* cacheDirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	NSString* cacheRoot = cacheDirs.count ? cacheDirs[0] : [NSHomeDirectory() stringByAppendingPathComponent: @"Library/Caches"];
	return [[cacheRoot stringByAppendingPathComponent: @"MoltenVK"] stringByAppendingPathComponent: @"detroit-msl-library-cache-full"];
}

static bool mvkDTRMSLLibraryDiskCacheEnabled() { return mvkDTRMSLLibraryCacheEnabled() && mvkDTRMSLLibraryDiskCacheDir() != nil; }

static NSString* mvkDTRMSLLibraryDiskCacheFilterPath() {
	const char* env = getenv("MVK_DTR_MSL_LIBRARY_DISK_CACHE_FILTER_PATH");
	if ( !env || !*env ) { return nil; }
	return [[NSString stringWithUTF8String: env] stringByExpandingTildeInPath];
}

static uint32_t mvkDTRShaderResourceLogMinCount() {
	const char* env = getenv("MVK_DTR_SHADER_RESOURCE_LOG_MIN_COUNT");
	uint32_t threshold = (env && *env) ? (uint32_t)strtoul(env, nullptr, 10) : 1024;
	return threshold ? threshold : 1;
}

static NSString* mvkDTRShaderLogPath() {
	const char* logPathEnv = getenv("MVK_DTR_BINARY_ARCHIVE_LOG_PATH");
	if (logPathEnv && *logPathEnv) {
		return [[NSString stringWithUTF8String: logPathEnv] stringByExpandingTildeInPath];
	}

	const char* archivePathEnv = getenv("MVK_DTR_BINARY_ARCHIVE_PATH");
	if (archivePathEnv && *archivePathEnv) {
		return [[[NSString stringWithUTF8String: archivePathEnv] stringByExpandingTildeInPath] stringByAppendingString: @".log"];
	}

	NSArray<NSString*>* cacheDirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	NSString* cacheRoot = cacheDirs.count ? cacheDirs[0] : [NSHomeDirectory() stringByAppendingPathComponent: @"Library/Caches"];
	return [[cacheRoot stringByAppendingPathComponent: @"MoltenVK"] stringByAppendingPathComponent: @"detroit-binary-archive.log"];
}

static void mvkDTRShaderLog(const char* fmt, ...) __printflike(1, 2);
static void mvkDTRShaderLog(const char* fmt, ...) {
	char msg[2048];
	va_list args;
	va_start(args, fmt);
	vsnprintf(msg, sizeof(msg), fmt, args);
	va_end(args);

	static mutex logLock;
	lock_guard<mutex> lock(logLock);
	@autoreleasepool {
		NSString* logPath = mvkDTRShaderLogPath();
		NSString* logDir = [logPath stringByDeletingLastPathComponent];
		[[NSFileManager defaultManager] createDirectoryAtPath: logDir withIntermediateDirectories: YES attributes: nil error: nil];

		FILE* logFile = fopen(logPath.fileSystemRepresentation, "a");
		if ( !logFile ) { return; }

		NSString* timestamp = [[NSDate date] descriptionWithLocale: nil];
		fprintf(logFile, "%s %s%s\n", timestamp.UTF8String, MVK_DTR_SHADER_LOG_PREFIX, msg);
		fclose(logFile);
	}
}

static const char* mvkDTRInferMSLStage(const string& msl) {
	if (msl.find("fragment ") != string::npos) { return "fragment"; }
	if (msl.find("vertex ") != string::npos) { return "vertex"; }
	if (msl.find("kernel ") != string::npos) { return "compute"; }
	return "unknown";
}

static const char* mvkDTRShaderStageName(spv::ExecutionModel stage) {
	switch (stage) {
		case spv::ExecutionModelVertex: return "vertex";
		case spv::ExecutionModelTessellationControl: return "tess-control";
		case spv::ExecutionModelTessellationEvaluation: return "tess-eval";
		case spv::ExecutionModelFragment: return "fragment";
		case spv::ExecutionModelGLCompute: return "compute";
		default: return "unknown";
	}
}

static void mvkDTRLogLargeShaderResources(const SPIRVToMSLConversionConfiguration* pShaderConfig,
										   const SPIRVToMSLConversionResult& conversionResult,
										   size_t moduleHash) {
	if ( !mvkDTRShaderResourceLogEnabled() ) { return; }

	uint32_t minCount = mvkDTRShaderResourceLogMinCount();
	for (const auto& rb : pShaderConfig->resourceBindings) {
		const auto& rbb = rb.resourceBinding;
		if (rbb.stage != pShaderConfig->options.entryPointStage || rbb.count < minCount) { continue; }

		mvkDTRShaderLog("large shader resource stage=%s entry=%s module=%016zx set=%u binding=%u count=%u used=%u basetype=%u msl_buffer=%u msl_texture=%u msl_sampler=%u msl_bytes=%zu arg_buffers=%u pad_arg_buffers=%u",
						 mvkDTRShaderStageName(pShaderConfig->options.entryPointStage),
						 pShaderConfig->options.entryPointName.c_str(),
						 moduleHash,
						 rbb.desc_set,
						 rbb.binding,
						 rbb.count,
						 rb.outIsUsedByShader ? 1 : 0,
						 (uint32_t)rbb.basetype,
						 rbb.msl_buffer,
						 rbb.msl_texture,
						 rbb.msl_sampler,
						 conversionResult.msl.size(),
						 pShaderConfig->options.mslOptions.argument_buffers ? 1 : 0,
						 pShaderConfig->options.mslOptions.pad_argument_buffer_resources ? 1 : 0);
	}
}

static NSString* mvkDTRShaderSlowDumpDir() {
	const char* dumpDirEnv = getenv("MVK_DTR_SHADER_SLOW_DUMP_DIR");
	if ( !dumpDirEnv || !*dumpDirEnv ) { return nil; }
	return [[NSString stringWithUTF8String: dumpDirEnv] stringByExpandingTildeInPath];
}

static void mvkDTRDumpSlowShader(const string& msl, const char* stage, size_t mslHash, uint64_t compileNanos) {
	NSString* dumpDir = mvkDTRShaderSlowDumpDir();
	if ( !dumpDir ) { return; }

	@autoreleasepool {
		[[NSFileManager defaultManager] createDirectoryAtPath: dumpDir withIntermediateDirectories: YES attributes: nil error: nil];
		NSString* fileName = [NSString stringWithFormat: @"slow-%s-%016zx-%.0fms.metal", stage, mslHash, (double)compileNanos / 1e6];
		NSString* filePath = [dumpDir stringByAppendingPathComponent: fileName];
		FILE* file = fopen(filePath.fileSystemRepresentation, "wb");
		if ( !file ) { return; }
		fwrite(msl.data(), 1, msl.size(), file);
		fclose(file);
		mvkDTRShaderLog("slow shader source dumped path=%s", filePath.UTF8String);
	}
}

struct MVKDTRMSLLibraryCacheKey {
	const void* device = nullptr;
	uint64_t deviceRegistryID = 0;
	size_t deviceNameHash = 0;
	size_t mslHash = 0;
	size_t mslSize = 0;
	size_t macroHash = 0;
	size_t macroCount = 0;
	uint32_t fpFastMathFlags = 0;
	bool isPositionInvariant = false;

	bool operator==(const MVKDTRMSLLibraryCacheKey& other) const {
		return device == other.device &&
			   deviceRegistryID == other.deviceRegistryID &&
			   deviceNameHash == other.deviceNameHash &&
			   mslHash == other.mslHash &&
			   mslSize == other.mslSize &&
			   macroHash == other.macroHash &&
			   macroCount == other.macroCount &&
			   fpFastMathFlags == other.fpFastMathFlags &&
			   isPositionInvariant == other.isPositionInvariant;
	}
};

struct MVKDTRMSLLibraryCacheKeyHasher {
	size_t operator()(const MVKDTRMSLLibraryCacheKey& key) const {
		size_t h = key.mslHash;
		h ^= (size_t)key.deviceRegistryID + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= key.deviceNameHash + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= key.mslSize + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= key.macroHash + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= key.macroCount + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= (size_t)key.fpFastMathFlags + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= (uintptr_t)key.device + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= (size_t)key.isPositionInvariant + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		return h;
	}
};

struct MVKDTRMSLLibraryCacheEntry {
	~MVKDTRMSLLibraryCacheEntry() { [library release]; }

	mutex lock;
	condition_variable cv;
	id<MTLLibrary> library = nil;
	bool compiling = true;
};

using MVKDTRMSLLibraryCache = unordered_map<MVKDTRMSLLibraryCacheKey, shared_ptr<MVKDTRMSLLibraryCacheEntry>, MVKDTRMSLLibraryCacheKeyHasher>;

static MVKDTRMSLLibraryCache& mvkDTRMSLLibraryCache() {
	static MVKDTRMSLLibraryCache cache;
	return cache;
}

static mutex& mvkDTRMSLLibraryCacheLock() {
	static mutex cacheLock;
	return cacheLock;
}

static size_t mvkDTRHashMSLMacros(const vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>>& macroDef) {
	size_t h = macroDef.size();
	for (const auto& md : macroDef) {
		h ^= mvkHash(md.first.name.data(), md.first.name.size()) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= (size_t)md.first.isFloat + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= (size_t)md.first.isSigned + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= md.second.value.ui64 + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		h ^= md.second.size + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
	}
	return h;
}

static size_t mvkDTRHashMTLDeviceName(id<MTLDevice> mtlDevice) {
	const char* name = mtlDevice.name ? mtlDevice.name.UTF8String : "";
	return mvkHash(name, strlen(name));
}

static bool mvkDTRParseMSLHashLine(const char* line, size_t& mslHash) {
	const char* hashStart = strstr(line, "msl_hash=");
	if (hashStart) {
		hashStart += strlen("msl_hash=");
	} else {
		hashStart = line;
		while (*hashStart && !isxdigit((unsigned char)*hashStart)) { hashStart++; }
	}

	if ( !isxdigit((unsigned char)*hashStart) ) { return false; }
	char* hashEnd = nullptr;
	unsigned long long parsedHash = strtoull(hashStart, &hashEnd, 16);
	if (hashEnd == hashStart) { return false; }
	mslHash = (size_t)parsedHash;
	return true;
}

static const unordered_set<size_t>* mvkDTRMSLLibraryDiskCacheFilter() {
	static bool enabled = false;
	static unordered_set<size_t> hashes;
	static once_flag initOnce;

	call_once(initOnce, [&] {
		@autoreleasepool {
			NSString* filterPath = mvkDTRMSLLibraryDiskCacheFilterPath();
			if ( !filterPath ) { return; }
			enabled = true;

			FILE* filterFile = fopen(filterPath.fileSystemRepresentation, "r");
			if ( !filterFile ) {
				if (mvkDTRShaderCacheLogEnabled()) {
					mvkDTRShaderLog("MSL disk library cache filter open failed path=%s", filterPath.UTF8String);
				}
				return;
			}

			char line[512];
			while (fgets(line, sizeof(line), filterFile)) {
				size_t mslHash = 0;
				if (mvkDTRParseMSLHashLine(line, mslHash)) { hashes.insert(mslHash); }
			}
			fclose(filterFile);

			if (mvkDTRShaderCacheLogEnabled()) {
				mvkDTRShaderLog("MSL disk library cache filter loaded path=%s hashes=%zu", filterPath.UTF8String, hashes.size());
			}
		}
	});

	return enabled ? &hashes : nullptr;
}

static bool mvkDTRMSLLibraryDiskCacheAllowsKey(const MVKDTRMSLLibraryCacheKey& key) {
	const unordered_set<size_t>* filter = mvkDTRMSLLibraryDiskCacheFilter();
	return !filter || filter->count(key.mslHash) != 0;
}

static bool mvkDTRMSLLibraryDiskCacheShouldDumpSource(const MVKDTRMSLLibraryCacheKey& key, uint64_t compileNanos) {
	if ( !mvkDTRMSLLibraryDiskCacheEnabled() || key.macroCount != 0 ) { return false; }

	const unordered_set<size_t>* filter = mvkDTRMSLLibraryDiskCacheFilter();
	if ( !filter || filter->count(key.mslHash) != 0 ) { return true; }

	return compileNanos >= mvkDTRShaderSlowCompileThresholdNS();
}

static NSString* mvkDTRMSLLibraryDiskCacheBaseName(const MVKDTRMSLLibraryCacheKey& key) {
	char name[256];
	snprintf(name, sizeof(name), "msl-v1-d%016llx-n%016zx-h%016zx-s%zx-m%016zx-c%zx-f%08x-i%u",
			 (unsigned long long)key.deviceRegistryID,
			 key.deviceNameHash,
			 key.mslHash,
			 key.mslSize,
			 key.macroHash,
			 key.macroCount,
			 key.fpFastMathFlags,
			 key.isPositionInvariant ? 1 : 0);
	return [NSString stringWithUTF8String: name];
}

static NSString* mvkDTRMSLLibraryDiskCachePath(const MVKDTRMSLLibraryCacheKey& key, NSString* extension) {
	NSString* cacheDir = mvkDTRMSLLibraryDiskCacheDir();
	if ( !cacheDir ) { return nil; }
	NSString* fileName = [mvkDTRMSLLibraryDiskCacheBaseName(key) stringByAppendingPathExtension: extension];
	return [cacheDir stringByAppendingPathComponent: fileName];
}

static id<MTLLibrary> mvkDTRLoadMSLLibraryFromDisk(id<MTLDevice> mtlDevice,
											 const MVKDTRMSLLibraryCacheKey& key,
											 uint64_t& loadNanos) {
	loadNanos = 0;
	if ( !mvkDTRMSLLibraryDiskCacheEnabled() || key.macroCount != 0 || !mvkDTRMSLLibraryDiskCacheAllowsKey(key) ) { return nil; }

	@autoreleasepool {
		NSString* metallibPath = mvkDTRMSLLibraryDiskCachePath(key, @"metallib");
		if ( ![[NSFileManager defaultManager] fileExistsAtPath: metallibPath] ) { return nil; }

		NSError* error = nil;
		uint64_t start = mvkGetTimestamp();
		id<MTLLibrary> lib = [mtlDevice newLibraryWithURL: [NSURL fileURLWithPath: metallibPath] error: &error];
		loadNanos = mvkGetElapsedNanoseconds(start);
		if (lib) {
			if (mvkDTRShaderCacheLogEnabled()) {
				mvkDTRShaderLog("MSL disk library cache hit path=%s msl_hash=%016zx msl_bytes=%zu load=%.1fms",
								 metallibPath.UTF8String,
								 key.mslHash,
								 key.mslSize,
								 (double)loadNanos / 1e6);
			}
			return lib;
		}

		if (mvkDTRShaderCacheLogEnabled()) {
			mvkDTRShaderLog("MSL disk library cache load failed path=%s msl_hash=%016zx error=%s",
							 metallibPath.UTF8String,
							 key.mslHash,
							 error ? error.localizedDescription.UTF8String : "<unknown>");
		}
		return nil;
	}
}

static void mvkDTRDumpMSLLibraryDiskCacheSource(const MVKDTRMSLLibraryCacheKey& key, const string& msl, uint64_t compileNanos) {
	if ( !mvkDTRMSLLibraryDiskCacheShouldDumpSource(key, compileNanos) ) { return; }

	static mutex dumpLock;
	lock_guard<mutex> lock(dumpLock);
	@autoreleasepool {
		NSString* cacheDir = mvkDTRMSLLibraryDiskCacheDir();
		[[NSFileManager defaultManager] createDirectoryAtPath: cacheDir withIntermediateDirectories: YES attributes: nil error: nil];

		NSString* metalPath = mvkDTRMSLLibraryDiskCachePath(key, @"metal");
		if ( ![[NSFileManager defaultManager] fileExistsAtPath: metalPath] ) {
			FILE* metalFile = fopen(metalPath.fileSystemRepresentation, "wb");
			if (metalFile) {
				fwrite(msl.data(), 1, msl.size(), metalFile);
				fclose(metalFile);
			}
		}

		NSString* metaPath = mvkDTRMSLLibraryDiskCachePath(key, @"meta");
		if ( ![[NSFileManager defaultManager] fileExistsAtPath: metaPath] ) {
			NSString* metallibPath = mvkDTRMSLLibraryDiskCachePath(key, @"metallib");
			FILE* metaFile = fopen(metaPath.fileSystemRepresentation, "wb");
			if (metaFile) {
				fprintf(metaFile, "metal=%s\n", metalPath.UTF8String);
				fprintf(metaFile, "metallib=%s\n", metallibPath.UTF8String);
				fprintf(metaFile, "msl_hash=%016zx\n", key.mslHash);
				fprintf(metaFile, "msl_bytes=%zu\n", key.mslSize);
				fprintf(metaFile, "fp_fast_math_flags=%u\n", key.fpFastMathFlags);
				fprintf(metaFile, "is_position_invariant=%u\n", key.isPositionInvariant ? 1 : 0);
				fprintf(metaFile, "macro_count=%zu\n", key.macroCount);
				fprintf(metaFile, "command_hint=xcrun -sdk macosx metal -o '%s' '%s'\n",
						metallibPath.UTF8String,
						metalPath.UTF8String);
				fclose(metaFile);
			}
		}
	}
}

static shared_ptr<MVKDTRMSLLibraryCacheEntry> mvkDTRGetMSLLibraryCacheEntry(const MVKDTRMSLLibraryCacheKey& key,
															 bool& shouldCompile) {
	lock_guard<mutex> lock(mvkDTRMSLLibraryCacheLock());
	auto& cache = mvkDTRMSLLibraryCache();
	auto iter = cache.find(key);
	if (iter != cache.end()) {
		shouldCompile = false;
		return iter->second;
	}

	shouldCompile = true;
	auto entry = make_shared<MVKDTRMSLLibraryCacheEntry>();
	cache[key] = entry;
	return entry;
}

static void mvkDTRRemoveMSLLibraryCacheEntry(const MVKDTRMSLLibraryCacheKey& key,
											 const shared_ptr<MVKDTRMSLLibraryCacheEntry>& entry) {
	lock_guard<mutex> lock(mvkDTRMSLLibraryCacheLock());
	auto& cache = mvkDTRMSLLibraryCache();
	auto iter = cache.find(key);
	if (iter != cache.end() && iter->second == entry) { cache.erase(iter); }
}

static id<MTLLibrary> mvkDTRNewMTLLibrary(MVKShaderLibraryCompiler* slc,
									 id<MTLDevice> mtlDevice,
									 NSString* nsSrc,
									 const string& msl,
									 const SPIRVToMSLConversionResultInfo& shaderConversionResultInfo,
									 const vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>>& macroDef,
									 uint64_t& compileNanos,
									 bool& cacheHit,
									 bool& diskCacheHit) {
	compileNanos = 0;
	cacheHit = false;
	diskCacheHit = false;
	bool processCacheEnabled = mvkDTRMSLLibraryCacheEnabled();
	bool diskCacheEnabled = mvkDTRMSLLibraryDiskCacheEnabled();
	if ( !processCacheEnabled && !diskCacheEnabled ) {
		uint64_t start = mvkGetTimestamp();
		id<MTLLibrary> lib = slc->newMTLLibrary(nsSrc, shaderConversionResultInfo, macroDef);
		compileNanos = mvkGetElapsedNanoseconds(start);
		return lib;
	}

	MVKDTRMSLLibraryCacheKey key;
	key.device = mtlDevice;
	key.deviceRegistryID = mtlDevice.registryID;
	key.deviceNameHash = mvkDTRHashMTLDeviceName(mtlDevice);
	key.mslHash = mvkHash(msl.data(), msl.size());
	key.mslSize = msl.size();
	key.macroHash = mvkDTRHashMSLMacros(macroDef);
	key.macroCount = macroDef.size();
	key.fpFastMathFlags = shaderConversionResultInfo.entryPoint.fpFastMathFlags;
	key.isPositionInvariant = shaderConversionResultInfo.isPositionInvariant;

	bool shouldCompile = false;
	auto entry = mvkDTRGetMSLLibraryCacheEntry(key, shouldCompile);
	if ( !shouldCompile ) {
		uint64_t waitStart = mvkGetTimestamp();
		unique_lock<mutex> entryLock(entry->lock);
		while (entry->compiling) { entry->cv.wait(entryLock); }
		compileNanos = mvkGetElapsedNanoseconds(waitStart);
		cacheHit = true;
		return entry->library ? [entry->library retain] : nil;
	}

	if (diskCacheEnabled) {
		id<MTLLibrary> diskLib = mvkDTRLoadMSLLibraryFromDisk(mtlDevice, key, compileNanos);
		if (diskLib) {
			diskCacheHit = true;
			{
				lock_guard<mutex> entryLock(entry->lock);
				entry->library = [diskLib retain];
				entry->compiling = false;
			}
			entry->cv.notify_all();
			return diskLib;
		}
	}

	uint64_t start = mvkGetTimestamp();
	id<MTLLibrary> lib = slc->newMTLLibrary(nsSrc, shaderConversionResultInfo, macroDef);
	compileNanos = mvkGetElapsedNanoseconds(start);
	if (lib) { mvkDTRDumpMSLLibraryDiskCacheSource(key, msl, compileNanos); }
	{
		lock_guard<mutex> entryLock(entry->lock);
		entry->library = [lib retain];
		entry->compiling = false;
	}
	entry->cv.notify_all();
	if ( !lib ) { mvkDTRRemoveMSLLibraryCacheEntry(key, entry); }
	return lib;
}

MVKMTLFunction::MVKMTLFunction(id<MTLFunction> mtlFunc, const SPIRVToMSLConversionResultInfo scRslts, MTLSize tgSize) {
	_mtlFunction = [mtlFunc retain];		// retained
	shaderConversionResults = scRslts;
	threadGroupSize = tgSize;
}

MVKMTLFunction::MVKMTLFunction(const MVKMTLFunction& other) {
	_mtlFunction = [other._mtlFunction retain];		// retained
	shaderConversionResults = other.shaderConversionResults;
	threadGroupSize = other.threadGroupSize;
}

MVKMTLFunction& MVKMTLFunction::operator=(const MVKMTLFunction& other) {
	// Retain new object first in case it's the same object
	[other._mtlFunction retain];
	[_mtlFunction release];
	_mtlFunction = other._mtlFunction;

	shaderConversionResults = other.shaderConversionResults;
	threadGroupSize = other.threadGroupSize;
	return *this;
}

MVKMTLFunction::~MVKMTLFunction() {
	[_mtlFunction release];
}


#pragma mark -
#pragma mark MVKShaderLibrary

// If the size of the workgroup dimension is specialized, extract it from the
// specialization info, otherwise use the value specified in the SPIR-V shader code.
static uint32_t getWorkgroupDimensionSize(const SPIRVWorkgroupSizeDimension& wgDim, const VkSpecializationInfo* pSpecInfo) {
	if (wgDim.isSpecialized && pSpecInfo) {
		for (uint32_t specIdx = 0; specIdx < pSpecInfo->mapEntryCount; specIdx++) {
			const VkSpecializationMapEntry* pMapEntry = &pSpecInfo->pMapEntries[specIdx];
			if (pMapEntry->constantID == wgDim.specializationID) {
				return *reinterpret_cast<uint32_t*>((uintptr_t)pSpecInfo->pData + pMapEntry->offset) ;
			}
		}
	}
	return wgDim.size;
}

MVKMTLFunction MVKShaderLibrary::getMTLFunction(const VkSpecializationInfo* pSpecializationInfo,
												VkPipelineCreationFeedback* pShaderFeedback,
												MVKShaderModule* shaderModule) {

	if ( !_mtlLibrary ) { return MVKMTLFunctionNull; }

	id<MTLLibrary> lib = _mtlLibrary;

	// If specialization happens on constants mapped to macro, find or compile a library variant
	// with proper macro definition instead of the "generic" library
	if (pSpecializationInfo && _maySpecializeWithMacro) {
		// Create the list of macro-value mapping
		vector<pair<uint32_t, MVKShaderMacroValue>> spec_list;
		for (uint32_t specIdx = 0; specIdx < pSpecializationInfo->mapEntryCount; specIdx++) {
			const VkSpecializationMapEntry* pMapEntry = &pSpecializationInfo->pMapEntries[specIdx];
			uint32_t const_id = pMapEntry->constantID;
			MVKShaderMacroValue macro_value = {};
			size_t size = min(pMapEntry->size, sizeof(macro_value.value));

			memcpy(&macro_value.value, (char *)pSpecializationInfo->pData + pMapEntry->offset, size);
			macro_value.size = size;
			if (_shaderConversionResultInfo.specializationMacros.find(const_id) != _shaderConversionResultInfo.specializationMacros.end()) {
				spec_list.push_back(make_pair(const_id, macro_value));
			}
		}

		if (!spec_list.empty()) {
			// Sort the specialization list before it is used as a key to index the variants
			std::sort(spec_list.begin(), spec_list.end());
			auto entry = _specializationVariants.find(spec_list);
			if (entry != _specializationVariants.end()) {
				lib = entry->second->_mtlLibrary;
			} else {
				MVKShaderLibrary *new_mvklib = new MVKShaderLibrary(_owner, _shaderConversionResultInfo, _compressedMSL, &spec_list);
				_specializationVariants[spec_list] = new_mvklib;
				lib = new_mvklib->_mtlLibrary;
			}
		}
	}


	@synchronized (getMTLDevice()) {
		@autoreleasepool {
			NSString* mtlFuncName = @(_shaderConversionResultInfo.entryPoint.mtlFunctionName.c_str());

			uint64_t startTime = pShaderFeedback ? mvkGetTimestamp() : getPerformanceTimestamp();
			id<MTLFunction> mtlFunc = [[lib newFunctionWithName: mtlFuncName] autorelease];
			addPerformanceInterval(getPerformanceStats().shaderCompilation.functionRetrieval, startTime);
			if (pShaderFeedback) {
				if (mtlFunc) {
					mvkEnableFlags(pShaderFeedback->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT);
				}
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}

			if (mtlFunc) {
				// If the Metal function expects to be specialized, populate Metal function constant values from
				// the Vulkan specialization info, and compile a specialized Metal function, otherwise simply use
				// the unspecialized Metal function.
				NSArray<MTLFunctionConstant*>* mtlFCs = mtlFunc.functionConstantsDictionary.allValues;
				if (mtlFCs.count > 0) {
					// The Metal shader contains function constants and expects to be specialized.
					// Populate the Metal function constant values from the Vulkan specialization info.
					MTLFunctionConstantValues* mtlFCVals = [[MTLFunctionConstantValues new] autorelease];
					if (pSpecializationInfo) {
						// Iterate through the provided Vulkan specialization entries, and populate the
						// Metal function constant value that matches the Vulkan specialization constantID.
						for (uint32_t specIdx = 0; specIdx < pSpecializationInfo->mapEntryCount; specIdx++) {
							const VkSpecializationMapEntry* pMapEntry = &pSpecializationInfo->pMapEntries[specIdx];
							for (MTLFunctionConstant* mfc in mtlFCs) {
								if (mfc.index == pMapEntry->constantID) {
									[mtlFCVals setConstantValue: ((char*)pSpecializationInfo->pData + pMapEntry->offset)
														   type: mfc.type
														atIndex: mfc.index];
									break;
								}
							}
						}
					}

					// Compile the specialized Metal function, and use it instead of the unspecialized Metal function.
					MVKFunctionSpecializer fs(_owner);
					if (pShaderFeedback) {
						startTime = mvkGetTimestamp();
					}
					mtlFunc = [fs.newMTLFunction(lib, mtlFuncName, mtlFCVals) autorelease];
					if (pShaderFeedback) {
						pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
					}
				}
			}

			// Set the debug name. First try name of shader module, otherwise try name of owner.
			NSString* dbName = shaderModule->getDebugName();
			if ( !dbName ) { dbName = _owner->getDebugName(); }
			_owner->setMetalObjectLabel(mtlFunc, dbName);

			auto& wgSize = _shaderConversionResultInfo.entryPoint.workgroupSize;
			return MVKMTLFunction(mtlFunc, _shaderConversionResultInfo, MTLSizeMake(getWorkgroupDimensionSize(wgSize.width, pSpecializationInfo),
																					getWorkgroupDimensionSize(wgSize.height, pSpecializationInfo),
																					getWorkgroupDimensionSize(wgSize.depth, pSpecializationInfo)));
		}
	}
}

void MVKShaderLibrary::setEntryPointName(string& funcName) {
	_shaderConversionResultInfo.entryPoint.mtlFunctionName = funcName;
}

void MVKShaderLibrary::setWorkgroupSize(uint32_t x, uint32_t y, uint32_t z) {
	auto& wgSize = _shaderConversionResultInfo.entryPoint.workgroupSize;
	wgSize.width.size = x;
	wgSize.height.size = y;
	wgSize.depth.size = z;
}

// Sets the cached MSL source code, after first compressing it.
void MVKShaderLibrary::compressMSL(const string& msl) {
	uint64_t startTime = getPerformanceTimestamp();
	_compressedMSL.compress(msl, getMVKConfig().shaderSourceCompressionAlgorithm);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslCompress, startTime);
}

// Decompresses the cached MSL into the string.
void MVKShaderLibrary::decompressMSL(string& msl) {
	uint64_t startTime = getPerformanceTimestamp();
	_compressedMSL.decompress(msl);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslDecompress, startTime);
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
								   const SPIRVToMSLConversionResult& conversionResult) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(true) {

	_shaderConversionResultInfo = conversionResult.resultInfo;
	compressMSL(conversionResult.msl);
	compileLibrary(conversionResult.msl);
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
								   const SPIRVToMSLConversionResultInfo& resultInfo,
								   const MVKCompressor<std::string> compressedMSL,
								   const vector<pair<uint32_t, MVKShaderMacroValue> >* specializationMacroDef) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(specializationMacroDef == nullptr) {

	_shaderConversionResultInfo = resultInfo;
	_compressedMSL = compressedMSL;
	string msl;
	decompressMSL(msl);
	compileLibrary(msl, specializationMacroDef);
}

void MVKShaderLibrary::compileLibrary(const string& msl,
									  const vector<pair<uint32_t, MVKShaderMacroValue> >* specializationMacroDef) {
	MVKShaderLibraryCompiler* slc = new MVKShaderLibraryCompiler(_owner);
	NSString* nsSrc = [[NSString alloc] initWithUTF8String: msl.c_str()];	// temp retained

	// If specialization macro is used, translate the id to macro information and pass it to compiler
	vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>> macro_def;
	if (specializationMacroDef) {
		for (auto& def: *specializationMacroDef) {
			const auto& macro_name_iter = _shaderConversionResultInfo.specializationMacros.find(def.first);
			if (macro_name_iter != _shaderConversionResultInfo.specializationMacros.end()) {
				macro_def.push_back(make_pair(macro_name_iter->second, def.second));
			}
		}
	}

	uint64_t dtrCompileNanos = 0;
	bool dtrMSLLibraryCacheHit = false;
	bool dtrMSLLibraryDiskCacheHit = false;
	_mtlLibrary = mvkDTRNewMTLLibrary(slc, getMTLDevice(), nsSrc, msl, _shaderConversionResultInfo, macro_def, dtrCompileNanos, dtrMSLLibraryCacheHit, dtrMSLLibraryDiskCacheHit);	// retained
	if (mvkDTRShaderCacheLogEnabled() && dtrMSLLibraryDiskCacheHit) {
		size_t mslHash = mvkHash(msl.data(), msl.size());
		mvkDTRShaderLog("MSL library disk cache hit entry=%s msl_hash=%016zx msl_bytes=%zu macro_count=%zu load=%.1fms success=%s",
						_shaderConversionResultInfo.entryPoint.mtlFunctionName.c_str(),
						mslHash,
						msl.size(),
						macro_def.size(),
						(double)dtrCompileNanos / 1e6,
						_mtlLibrary ? "1" : "0");
	}
	if (mvkDTRShaderCacheLogEnabled() && dtrMSLLibraryCacheHit) {
		size_t mslHash = mvkHash(msl.data(), msl.size());
		mvkDTRShaderLog("MSL library cache hit entry=%s msl_hash=%016zx msl_bytes=%zu macro_count=%zu wait=%.1fms success=%s",
						_shaderConversionResultInfo.entryPoint.mtlFunctionName.c_str(),
						mslHash,
						msl.size(),
						macro_def.size(),
						(double)dtrCompileNanos / 1e6,
						_mtlLibrary ? "1" : "0");
	}
	if (mvkDTRShaderCacheLogEnabled() && !dtrMSLLibraryCacheHit && !dtrMSLLibraryDiskCacheHit && dtrCompileNanos >= mvkDTRShaderSlowCompileThresholdNS()) {
		size_t mslHash = mvkHash(msl.data(), msl.size());
		const char* stage = mvkDTRInferMSLStage(msl);
		mvkDTRShaderLog("slow Metal library compile stage=%s entry=%s msl_hash=%016zx msl_bytes=%zu macro_count=%zu elapsed=%.1fms success=%s",
						stage,
						_shaderConversionResultInfo.entryPoint.mtlFunctionName.c_str(),
						mslHash,
						msl.size(),
						macro_def.size(),
						(double)dtrCompileNanos / 1e6,
						_mtlLibrary ? "1" : "0");
		mvkDTRDumpSlowShader(msl, stage, mslHash, dtrCompileNanos);
	}
	[nsSrc release];														// release temp string
	slc->destroy();
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
                                   const void* mslCompiledCodeData,
                                   size_t mslCompiledCodeLength) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(false) {

    uint64_t startTime = getPerformanceTimestamp();
    @autoreleasepool {
        dispatch_data_t shdrData = dispatch_data_create(mslCompiledCodeData,
                                                        mslCompiledCodeLength,
                                                        NULL,
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError* err = nil;
        _mtlLibrary = [getMTLDevice() newLibraryWithData: shdrData error: &err];    // retained
        handleCompilationError(err, "Compiled shader module creation");
        [shdrData release];
    }
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslLoad, startTime);
}

MVKShaderLibrary::MVKShaderLibrary(const MVKShaderLibrary& other) :
	MVKBaseDeviceObject(other._device),
	_owner(other._owner),
	_maySpecializeWithMacro(other._maySpecializeWithMacro),
	_specializationVariants(other._specializationVariants) {

	_mtlLibrary = [other._mtlLibrary retain];
	_shaderConversionResultInfo = other._shaderConversionResultInfo;
	_compressedMSL = other._compressedMSL;
}

MVKShaderLibrary& MVKShaderLibrary::operator=(const MVKShaderLibrary& other) {
	if (_mtlLibrary != other._mtlLibrary) {
		[_mtlLibrary release];
		_mtlLibrary = [other._mtlLibrary retain];
	}
	_owner = other._owner;
	_shaderConversionResultInfo = other._shaderConversionResultInfo;
	_compressedMSL = other._compressedMSL;
	return *this;
}

// If err object is nil, the compilation succeeded without any warnings.
// If err object exists, and the MTLLibrary was created, the compilation succeeded, but with warnings.
// If err object exists, and the MTLLibrary was not created, the compilation failed.
void MVKShaderLibrary::handleCompilationError(NSError* err, const char* opDesc) {
    if ( !err ) return;

    if (_mtlLibrary) {
        MVKLogInfo("%s succeeded with warnings (Error code %li):\n%s", opDesc, (long)err.code, err.localizedDescription.UTF8String);
    } else {
		_owner->setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED,
												   "%s failed (Error code %li):\n%s",
												   opDesc, (long)err.code,
												   err.localizedDescription.UTF8String));
    }
}

MVKShaderLibrary::~MVKShaderLibrary() {
	[_mtlLibrary release];

	for (auto& item: _specializationVariants) {
		delete item.second;
	}
}


#pragma mark -
#pragma mark MVKShaderLibraryCache

MVKShaderLibrary* MVKShaderLibraryCache::getShaderLibrary(SPIRVToMSLConversionConfiguration* pShaderConfig,
														  MVKShaderModule* shaderModule, MVKPipeline* pipeline,
														  bool* pWasAdded, VkPipelineCreationFeedback* pShaderFeedback,
														  uint64_t startTime) {
	bool wasAdded = false;
	MVKShaderLibrary* shLib = findShaderLibrary(pShaderConfig, pShaderFeedback, startTime);
	if ( !shLib && !pipeline->shouldFailOnPipelineCompileRequired() ) {
		SPIRVToMSLConversionResult conversionResult;
		if (shaderModule->convert(pShaderConfig, conversionResult)) {
			shLib = addShaderLibrary(pShaderConfig, conversionResult);
			if (pShaderFeedback) {
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}
			wasAdded = true;
		}
	}

	if (pWasAdded) { *pWasAdded = wasAdded; }

	return shLib;
}

// Finds and returns a shader library matching the shader config, or returns nullptr if it doesn't exist.
// If a match is found, the shader config is aligned with the shader config of the matching library.
MVKShaderLibrary* MVKShaderLibraryCache::findShaderLibrary(SPIRVToMSLConversionConfiguration* pShaderConfig,
														   VkPipelineCreationFeedback* pShaderFeedback,
														   uint64_t startTime) {
	for (auto& slPair : _shaderLibraries) {
		if (slPair.first.matches(*pShaderConfig)) {
			pShaderConfig->alignWith(slPair.first);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.shaderLibraryFromCache, startTime);
			if (pShaderFeedback) {
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}
			return slPair.second;
		}
	}
	return nullptr;
}

// Adds and returns a new shader library configured from the specified conversion configuration.
MVKShaderLibrary* MVKShaderLibraryCache::addShaderLibrary(const SPIRVToMSLConversionConfiguration* pShaderConfig,
														  const SPIRVToMSLConversionResult& conversionResult) {
	MVKShaderLibrary* shLib = new MVKShaderLibrary(_owner, conversionResult);
	_shaderLibraries.emplace_back(*pShaderConfig, shLib);
	return shLib;
}

// Adds and returns a new shader library configured from contents read from a pipeline cache.
MVKShaderLibrary* MVKShaderLibraryCache::addShaderLibrary(const SPIRVToMSLConversionConfiguration* pShaderConfig,
														  const SPIRVToMSLConversionResultInfo& resultInfo,
														  const MVKCompressor<std::string> compressedMSL) {
	MVKShaderLibrary* shLib = new MVKShaderLibrary(_owner, resultInfo, compressedMSL);
	_shaderLibraries.emplace_back(*pShaderConfig, shLib);
	return shLib;
}

// Merge another shader library cache with this one. Handle null input.
void MVKShaderLibraryCache::merge(MVKShaderLibraryCache* other) {
	if ( !other ) { return; }
	for (auto& otherPair : other->_shaderLibraries) {
		if ( !findShaderLibrary(&otherPair.first) ) {
			_shaderLibraries.emplace_back(otherPair.first, new MVKShaderLibrary(*otherPair.second));
			_shaderLibraries.back().second->_owner = _owner;
		}
	}
}

MVKShaderLibraryCache::~MVKShaderLibraryCache() {
	for (auto& slPair : _shaderLibraries) { slPair.second->destroy(); }
}


#pragma mark -
#pragma mark MVKShaderModule

MVKMTLFunction MVKShaderModule::getMTLFunction(SPIRVToMSLConversionConfiguration* pShaderConfig,
											   const VkSpecializationInfo* pSpecializationInfo,
											   MVKPipeline* pipeline,
											   VkPipelineCreationFeedback* pShaderFeedback) {
	MVKShaderLibrary* mvkLib = _directMSLLibrary;
	if ( !mvkLib ) {
		uint64_t startTime = pShaderFeedback ? mvkGetTimestamp() : getPerformanceTimestamp();
		MVKPipelineCache* pipelineCache = pipeline->getPipelineCache();
		if (pipelineCache) {
			mvkLib = pipelineCache->getShaderLibrary(pShaderConfig, this, pipeline, pShaderFeedback, startTime);
		} else {
			lock_guard<mutex> lock(_accessLock);
			mvkLib = _shaderLibraryCache.getShaderLibrary(pShaderConfig, this, pipeline, nullptr, pShaderFeedback, startTime);
		}
	} else {
		mvkLib->setEntryPointName(pShaderConfig->options.entryPointName);
		pShaderConfig->markAllInterfaceVarsAndResourcesUsed();
	}

	return mvkLib ? mvkLib->getMTLFunction(pSpecializationInfo, pShaderFeedback, this) : MVKMTLFunctionNull;
}

bool MVKShaderModule::convert(SPIRVToMSLConversionConfiguration* pShaderConfig,
							  SPIRVToMSLConversionResult& conversionResult) {
	const auto& mvkCfg = getMVKConfig();
	bool shouldLogCode = mvkCfg.debugMode;
	bool shouldLogEstimatedGLSL = shouldLogCode && mvkCfg.shaderLogEstimatedGLSL;

	uint64_t startTime = getPerformanceTimestamp();
	bool wasConverted = _spvConverter.convert(*pShaderConfig, conversionResult, shouldLogCode, shouldLogCode, shouldLogEstimatedGLSL);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.spirvToMSL, startTime);
	if (wasConverted) { mvkDTRLogLargeShaderResources(pShaderConfig, conversionResult, _key.codeHash); }

	const char* dumpDir = getMVKConfig().shaderDumpDir;
	if (dumpDir && *dumpDir) {
		char path[PATH_MAX];
		const char* type;
		switch (pShaderConfig->options.entryPointStage) {
			case spv::ExecutionModelVertex:                 type = "-vs"; break;
			case spv::ExecutionModelTessellationControl:    type = "-tcs"; break;
			case spv::ExecutionModelTessellationEvaluation: type = "-tes"; break;
			case spv::ExecutionModelFragment:               type = "-fs"; break;
			case spv::ExecutionModelGeometry:               type = "-gs"; break;
			case spv::ExecutionModelTaskNV:                 type = "-ts"; break;
			case spv::ExecutionModelMeshNV:                 type = "-ms"; break;
			case spv::ExecutionModelGLCompute:              type = "-cs"; break;
			default:                                        type = "";    break;
		}
		mkdir(dumpDir, 0755);
		snprintf(path, sizeof(path), "%s/shader%s-%016zx.spv", dumpDir, type, _key.codeHash);
		FILE* file = fopen(path, "wb");
		if (file) {
			fwrite(_spvConverter.getSPIRV().data(), sizeof(uint32_t), _spvConverter.getSPIRV().size(), file);
			fclose(file);
		}
		snprintf(path, sizeof(path), "%s/shader%s-%016zx.metal", dumpDir, type, _key.codeHash);
		file = fopen(path, "wb");
		if (file) {
			if (wasConverted) {
				fwrite(conversionResult.msl.data(), 1, conversionResult.msl.size(), file);
				fclose(file);
			} else {
				fputs("Failed to convert:\n", file);
				fwrite(conversionResult.resultLog.data(), 1, conversionResult.resultLog.size(), file);
				fclose(file);
			}
		}
	}

	if (wasConverted) {
		if (shouldLogCode) { MVKLogInfo("%s", conversionResult.resultLog.c_str()); }
	} else {
		reportError(VK_ERROR_INITIALIZATION_FAILED, "Unable to convert SPIR-V to MSL:\n%s", conversionResult.resultLog.c_str());
	}
	return wasConverted;
}

void MVKShaderModule::setWorkgroupSize(uint32_t x, uint32_t y, uint32_t z) {
	if(_directMSLLibrary) { _directMSLLibrary->setWorkgroupSize(x, y, z); }
}


#pragma mark Construction

MVKShaderModule::MVKShaderModule(MVKDevice* device,
								 const VkShaderModuleCreateInfo* pCreateInfo) : MVKVulkanAPIDeviceObject(device), _shaderLibraryCache(this) {

	_directMSLLibrary = nullptr;

	size_t codeSize = pCreateInfo->codeSize;

    // Ensure something is there.
    if ( (pCreateInfo->pCode == VK_NULL_HANDLE) || (codeSize < 4) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateShaderModule(): Shader module contains no shader code."));
		return;
	}

	size_t codeHash = 0;

	// Retrieve the magic number to determine what type of shader code has been loaded.
	// NOTE: Shader code should be submitted as SPIR-V. Although some simple direct MSL shaders may work,
	// direct loading of MSL source code or compiled MSL code is not officially supported at this time.
	// Future versions of MoltenVK may support direct MSL submission again.
	uint32_t magicNum = *pCreateInfo->pCode;
	switch (magicNum) {
		case kMVKMagicNumberSPIRVCode: {					// SPIR-V code
			size_t spvCount = (codeSize + 3) >> 2;			// Round up if byte length not exactly on uint32_t boundary

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(pCreateInfo->pCode, spvCount);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			_spvConverter.setSPIRV(pCreateInfo->pCode, spvCount);

			break;
		}
		case kMVKMagicNumberMSLSourceCode: {				// MSL source code
			size_t hdrSize = sizeof(MVKMSLSPIRVHeader);
			char* pMSLCode = (char*)(uintptr_t(pCreateInfo->pCode) + hdrSize);
			size_t mslCodeLen = codeSize - hdrSize;

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(&magicNum);
			codeHash = mvkHash(pMSLCode, mslCodeLen, codeHash);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			SPIRVToMSLConversionResult conversionResult;
			conversionResult.msl = pMSLCode;
			_directMSLLibrary = new MVKShaderLibrary(this, conversionResult);

			break;
		}
		case kMVKMagicNumberMSLCompiledCode: {				// MSL compiled binary code
			size_t hdrSize = sizeof(MVKMSLSPIRVHeader);
			char* pMSLCode = (char*)(uintptr_t(pCreateInfo->pCode) + hdrSize);
			size_t mslCodeLen = codeSize - hdrSize;

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(&magicNum);
			codeHash = mvkHash(pMSLCode, mslCodeLen, codeHash);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			_directMSLLibrary = new MVKShaderLibrary(this, (void*)(pMSLCode), mslCodeLen);

			break;
		}
		default:
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateShaderModule(): The SPIR-V contains an invalid magic number %x.", magicNum));
			break;
	}

	_key = MVKShaderModuleKey(codeSize, codeHash);
}

MVKShaderModule::~MVKShaderModule() {
	if (_directMSLLibrary) { _directMSLLibrary->destroy(); }
}


#pragma mark -
#pragma mark MVKShaderLibraryCompiler

id<MTLLibrary> MVKShaderLibraryCompiler::newMTLLibrary(NSString* mslSourceCode,
													   const SPIRVToMSLConversionResultInfo& shaderConversionResults,
													   const vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>>& specializationMacroDef) {
	unique_lock<mutex> lock(_completionLock);

	compile(lock, ^{
		auto mtlDev = getMTLDevice();
		@synchronized (mtlDev) {
			@autoreleasepool {
				auto mtlCompileOptions = getDevice()->getMTLCompileOptions(shaderConversionResults.entryPoint.fpFastMathFlags,
																		   shaderConversionResults.isPositionInvariant);
				if (!specializationMacroDef.empty()) {
					size_t macro_count = specializationMacroDef.size();
					NSString *macro_names[macro_count];
					NSNumber *macro_values[macro_count];
					for (uint32_t i = 0; i < specializationMacroDef.size(); i++) {
						macro_names[i] = @(specializationMacroDef[i].first.name.c_str());
						macro_values[i] = getMacroValue(specializationMacroDef[i].first, specializationMacroDef[i].second);
					}
					mtlCompileOptions.preprocessorMacros = [NSDictionary dictionaryWithObjects: macro_values
																					   forKeys: macro_names
																						 count: macro_count];
				}
				logCompilation(mtlCompileOptions);

				[mtlDev newLibraryWithSource: mslSourceCode
									options: mtlCompileOptions
						completionHandler: ^(id<MTLLibrary> mtlLib, NSError* error) {
							bool isLate = compileComplete(mtlLib, error);
							if (isLate) { destroy(); }
						}];
			}
		}
	});

	return [_mtlLibrary retain];
}

NSNumber *MVKShaderLibraryCompiler::getMacroValue(const MSLSpecializationMacroInfo& info,
												  const MVKShaderMacroValue& value) {
	NSNumber *result;

	if (info.isFloat) {
		if (value.size == sizeof(double)) {
			result = [NSNumber numberWithDouble: value.value.f64];
		} else {
			result = [NSNumber numberWithFloat: value.value.f32];
		}
	} else {
		if (info.isSigned) {
			switch (value.size) {
				case 1:
					result = [NSNumber numberWithChar: value.value.si8];
					break;
				case 2:
					result = [NSNumber numberWithShort: value.value.si16];
					break;
				case 4:
					result = [NSNumber numberWithInt: value.value.si32];
					break;
				case 8:
					result = [NSNumber numberWithLongLong: value.value.si64];
					break;
				default:
					result = [NSNumber numberWithInt: value.value.si32];
					break;
			}
		} else {
			switch (value.size) {
				case 1:
					result = [NSNumber numberWithUnsignedChar: value.value.ui8];
					break;
				case 2:
					result = [NSNumber numberWithUnsignedShort: value.value.ui16];
					break;
				case 4:
					result = [NSNumber numberWithUnsignedInt: value.value.ui32];
					break;
				case 8:
					result = [NSNumber numberWithUnsignedLongLong: value.value.ui64];
					break;
				default:
					result = [NSNumber numberWithUnsignedInt: value.value.ui32];
					break;
			}
		}
	}

	return result;
}

void MVKShaderLibraryCompiler::handleError() {
	if (_mtlLibrary) {
		MVKLogInfo("%s compilation succeeded with warnings (Error code %li):\n%s", _compilerType.c_str(),
				   (long)_compileError.code, _compileError.localizedDescription.UTF8String);
	} else {
		MVKMetalCompiler::handleError();
	}
}

bool MVKShaderLibraryCompiler::compileComplete(id<MTLLibrary> mtlLibrary, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlLibrary = [mtlLibrary retain];		// retained
	return endCompile(compileError);
}

void MVKShaderLibraryCompiler::logCompilation(MTLCompileOptions* mtlCompOpt) {
	if ( !getMVKConfig().debugMode ) { return; }

#if MVK_XCODE_16
	if ([mtlCompOpt respondsToSelector: @selector(mathMode)]) {
		const char* mathModeName = "Unknown";
		switch (mtlCompOpt.mathMode) {
			case MTLMathModeFast:
				mathModeName = "Fast";
				break;
			case MTLMathModeRelaxed:
				mathModeName = "Relaxed";
				break;
			case MTLMathModeSafe:
				mathModeName = "Safe";
				break;
			default:
				break;
		}
		const char* mathFPFName = "Unknown";
		switch (mtlCompOpt.mathFloatingPointFunctions) {
			case MTLMathFloatingPointFunctionsFast:
				mathFPFName = "Fast";
				break;
			case MTLMathFloatingPointFunctionsPrecise:
				mathFPFName = "Precise";
				break;
			default:
				break;
		}
		MVKLogInfo("Compiling Metal shader with MathMode %s, MathFloatingPointFunctions %s, and PreserveInvariance %sabled.",
				   mathModeName, mathFPFName, mtlCompOpt.preserveInvariance ? "en" : "dis");
	} else
#endif
	{
		MVKLogInfo("Compiling Metal shader with FastMath %sabled and PreserveInvariance %sabled.",
				   mtlCompOpt.fastMathEnabled ? "en" : "dis", mtlCompOpt.preserveInvariance ? "en" : "dis");
	}
}


#pragma mark Construction

MVKShaderLibraryCompiler::~MVKShaderLibraryCompiler() {
	[_mtlLibrary release];
}


#pragma mark -
#pragma mark MVKFunctionSpecializer

id<MTLFunction> MVKFunctionSpecializer::newMTLFunction(id<MTLLibrary> mtlLibrary,
													   NSString* funcName,
													   MTLFunctionConstantValues* constantValues) {
	unique_lock<mutex> lock(_completionLock);

	compile(lock, ^{
		[mtlLibrary newFunctionWithName: funcName
						 constantValues: constantValues
					  completionHandler: ^(id<MTLFunction> mtlFunc, NSError* error) {
						  bool isLate = compileComplete(mtlFunc, error);
						  if (isLate) { destroy(); }
					  }];
	});

	return [_mtlFunction retain];
}

bool MVKFunctionSpecializer::compileComplete(id<MTLFunction> mtlFunction, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlFunction = [mtlFunction retain];		// retained
	return endCompile(compileError);
}

#pragma mark Construction

MVKFunctionSpecializer::~MVKFunctionSpecializer() {
	[_mtlFunction release];
}
