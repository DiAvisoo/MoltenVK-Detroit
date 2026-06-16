/*
 * MVKSurface.mm
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

#include "MVKSurface.h"
#include "MVKSwapchain.h"
#include "MVKInstance.h"
#include "MVKFoundation.h"
#include "MVKOSExtensions.h"
#include "mvk_datatypes.hpp"
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <pthread.h>

#import "CAMetalLayer+MoltenVK.h"
#import "MVKBlockObserver.h"
#import <Foundation/NSMapTable.h>

#ifdef VK_USE_PLATFORM_IOS_MVK
#	define PLATFORM_VIEW_CLASS	UIView
#	import <UIKit/UIView.h>
#endif

#ifdef VK_USE_PLATFORM_MACOS_MVK
#	define PLATFORM_VIEW_CLASS	NSView
#	import <AppKit/NSView.h>
#	import <AppKit/NSScreen.h>
#	import <AppKit/NSWindow.h>
#endif


// We need to double-dereference the name to first convert to the platform symbol, then to a string.
#define STR_PLATFORM(NAME) #NAME
#define STR(NAME) STR_PLATFORM(NAME)

// As defined in the Vulkan spec, represents an undefined extent.
// Spec is currently somewhat ambiguous about whether an undefined surface extent should be updated
// once a swapchain is attached, but consensus amoung the spec authors is that it should not.
static constexpr VkExtent2D kMVKUndefinedExtent = {0xFFFFFFFF, 0xFFFFFFFF};

static bool mvkDTRBoolEnvValue(const char* name, bool defaultValue) {
	const char* env = getenv(name);
	if ( !env ) { return defaultValue; }
	while (*env == ' ' || *env == '\t' || *env == '\n' || *env == '\r') { env++; }
	if (*env == '0') { return false; }
	if (*env == '1') { return true; }
	return defaultValue;
}

static bool mvkDTRSurfaceReplaceLayerEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_SURFACE_REPLACE_LAYER", false);
}

static bool mvkDTRSurfaceCacheWindowLayerEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_SURFACE_CACHE_WINDOW_LAYER", true);
}

static bool mvkDTRDisableLayerActionsEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_DISABLE_LAYER_ACTIONS", true);
}

static bool mvkDTRSurfaceStableWindowLayerEnabled() {
	return mvkDTRBoolEnvValue("MVK_DTR_SURFACE_STABLE_WINDOW_LAYER", true);
}

[[maybe_unused]] static bool mvkDTRSurfaceLogEnabled() {
	return false;
}

static bool mvkDTRSurfaceLogNativeEnabled() {
	return false;
}

[[maybe_unused]] static uint64_t mvkDTRCurrentThreadID() {
	uint64_t tid = 0;
	pthread_threadid_np(pthread_self(), &tid);
	return tid;
}

[[maybe_unused]] static NSString* mvkDTRSurfaceLogPath() {
	return nil;
}

template<typename... Args> static inline void mvkDTRDiscardLogArgs(Args&&...) {}
#define mvkDTRSurfaceLog(...) do { if (false) { mvkDTRDiscardLogArgs(__VA_ARGS__); } } while (false)

static void mvkDTRLogLayerNativeState(const char* stage, const void* surface, CAMetalLayer* layer, const void* activeSwapchain) {
	if ( !mvkDTRSurfaceLogNativeEnabled() ) { return; }

	if ( !layer ) {
		mvkDTRSurfaceLog("native state stage=%s surface=%p layer=0 active_swapchain=%p", stage, surface, activeSwapchain);
		return;
	}

	mvkDispatchToMainAndWait(^{
		@autoreleasepool {
			id delegate = layer.delegate;
			NSString* layerClass = NSStringFromClass(layer.class);
			NSString* delegateClass = delegate ? NSStringFromClass([delegate class]) : @"";
			CGRect bounds = layer.bounds;
			CGRect frame = layer.frame;
			CGPoint position = layer.position;
			CGPoint anchor = layer.anchorPoint;
			CGSize drawable = layer.drawableSize;
			CGSize natural = layer.naturalDrawableSizeMVK;
			mvkDTRSurfaceLog("native layer stage=%s surface=%p layer=%p class=%s delegate=%p delegate_class=%s superlayer=%p active_swapchain=%p bounds=%.1f,%.1f %.1fx%.1f frame=%.1f,%.1f %.1fx%.1f drawable=%.0fx%.0f natural=%.0fx%.0f contents_scale=%.3f position=%.1f,%.1f anchor=%.2f,%.2f hidden=%u opaque=%u opacity=%.3f name=%s",
						 stage, surface, layer, layerClass.UTF8String, delegate, delegateClass.UTF8String, layer.superlayer, activeSwapchain,
						 bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
						 frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
						 drawable.width, drawable.height, natural.width, natural.height, layer.contentsScale,
						 position.x, position.y, anchor.x, anchor.y, layer.hidden ? 1 : 0, layer.opaque ? 1 : 0,
						 layer.opacity, (layer.name ?: @"").UTF8String);

#ifdef VK_USE_PLATFORM_MACOS_MVK
			if ([delegate isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
				PLATFORM_VIEW_CLASS* view = (PLATFORM_VIEW_CLASS*)delegate;
				NSString* viewClass = NSStringFromClass(view.class);
				CGRect viewFrame = view.frame;
				CGRect viewBounds = view.bounds;
				CGRect visibleRect = view.visibleRect;
				mvkDTRSurfaceLog("native view stage=%s surface=%p view=%p class=%s layer=%p same_layer=%u superview=%p window=%p frame=%.1f,%.1f %.1fx%.1f bounds=%.1f,%.1f %.1fx%.1f visible=%.1f,%.1f %.1fx%.1f wants_layer=%u hidden=%u in_live_resize=%u",
							 stage, surface, view, viewClass.UTF8String, view.layer, view.layer == layer ? 1 : 0, view.superview, view.window,
							 viewFrame.origin.x, viewFrame.origin.y, viewFrame.size.width, viewFrame.size.height,
							 viewBounds.origin.x, viewBounds.origin.y, viewBounds.size.width, viewBounds.size.height,
							 visibleRect.origin.x, visibleRect.origin.y, visibleRect.size.width, visibleRect.size.height,
							 view.wantsLayer ? 1 : 0, view.hidden ? 1 : 0, view.inLiveResize ? 1 : 0);
				NSWindow* window = view.window;
				if (window) {
					CGRect windowFrame = window.frame;
					CGRect contentFrame = window.contentView ? window.contentView.frame : CGRectZero;
					NSScreen* screen = window.screen;
					mvkDTRSurfaceLog("native window stage=%s surface=%p window=%p content_view=%p screen=%p title=%s frame=%.1f,%.1f %.1fx%.1f content=%.1f,%.1f %.1fx%.1f backing=%.3f visible=%u key=%u mini=%u fullscreen=%u style=0x%llx occlusion=0x%lx",
								 stage, surface, window, window.contentView, screen, (window.title ?: @"").UTF8String,
								 windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height,
								 contentFrame.origin.x, contentFrame.origin.y, contentFrame.size.width, contentFrame.size.height,
								 window.backingScaleFactor, window.visible ? 1 : 0, window.keyWindow ? 1 : 0, window.miniaturized ? 1 : 0,
								 (window.styleMask & NSWindowStyleMaskFullScreen) ? 1 : 0, (unsigned long long)window.styleMask, (unsigned long)window.occlusionState);
					if (screen) {
						CGRect screenFrame = screen.frame;
						CGRect visibleFrame = screen.visibleFrame;
						NSNumber* screenNumber = [screen.deviceDescription objectForKey: @"NSScreenNumber"];
						mvkDTRSurfaceLog("native screen stage=%s surface=%p screen=%p name=%s frame=%.1f,%.1f %.1fx%.1f visible=%.1f,%.1f %.1fx%.1f backing=%.3f number=%llu",
									 stage, surface, screen, (screen.localizedName ?: @"").UTF8String,
									 screenFrame.origin.x, screenFrame.origin.y, screenFrame.size.width, screenFrame.size.height,
									 visibleFrame.origin.x, visibleFrame.origin.y, visibleFrame.size.width, visibleFrame.size.height,
									 screen.backingScaleFactor, screenNumber ? screenNumber.unsignedLongLongValue : 0ull);
					}
				}
			}
#endif
		}
	});
}

#ifdef VK_USE_PLATFORM_MACOS_MVK
static void mvkDTRRunWithDisabledLayerActions(void (^block)(void)) {
	if ( !mvkDTRDisableLayerActionsEnabled() ) {
		block();
		return;
	}

	[CATransaction begin];
	[CATransaction setDisableActions: YES];
	[CATransaction setAnimationDuration: 0.0];
	block();
	[CATransaction commit];
}

static NSDictionary* mvkDTRDisabledLayerActions() {
	static NSDictionary* disabledActions = [@{
		@"anchorPoint": [NSNull null],
		@"backgroundColor": [NSNull null],
		@"bounds": [NSNull null],
		@"contents": [NSNull null],
		@"contentsGravity": [NSNull null],
		@"contentsScale": [NSNull null],
		@"drawableSize": [NSNull null],
		@"frame": [NSNull null],
		@"hidden": [NSNull null],
		@"opacity": [NSNull null],
		@"position": [NSNull null],
		@"sublayers": [NSNull null],
		@"transform": [NSNull null],
		@"zPosition": [NSNull null],
		kCAOnOrderIn: [NSNull null],
		kCAOnOrderOut: [NSNull null],
		kCATransition: [NSNull null],
	} retain];
	return disabledActions;
}

static void mvkDTRInstallDisabledLayerActions(CALayer* layer) {
	if ( !mvkDTRDisableLayerActionsEnabled() || !layer ) { return; }

	NSMutableDictionary* actions = layer.actions ? [layer.actions mutableCopy] : [NSMutableDictionary new];
	[actions addEntriesFromDictionary: mvkDTRDisabledLayerActions()];
	layer.actions = actions;
	[actions release];
}

static NSMapTable* mvkDTRSurfaceWindowLayerCache() {
	static NSMapTable* cache = [[NSMapTable weakToStrongObjectsMapTable] retain];
	return cache;
}

static NSMapTable* mvkDTRSurfaceWindowHostLayerCache() {
	static NSMapTable* cache = [[NSMapTable weakToStrongObjectsMapTable] retain];
	return cache;
}

static void mvkDTRCopyReusableLayerState(CAMetalLayer* dstLayer, CAMetalLayer* srcLayer) {
	if ( !dstLayer || !srcLayer || dstLayer == srcLayer ) { return; }
	CGSize srcDrawableSize = srcLayer.drawableSize;

	dstLayer.bounds = srcLayer.bounds;
	dstLayer.frame = srcLayer.frame;
	dstLayer.position = srcLayer.position;
	dstLayer.anchorPoint = srcLayer.anchorPoint;
	dstLayer.contentsScale = srcLayer.contentsScale;
	if (srcDrawableSize.width > 0.0 && srcDrawableSize.height > 0.0) {
		dstLayer.drawableSize = srcDrawableSize;
	} else {
		mvkDTRSurfaceLog("window layer cache skip drawableSize copy dst_layer=%p src_layer=%p drawable=%.0fx%.0f", dstLayer, srcLayer, srcDrawableSize.width, srcDrawableSize.height);
	}
	dstLayer.hidden = srcLayer.hidden;
	dstLayer.opaque = srcLayer.opaque;
	dstLayer.opacity = srcLayer.opacity;
	dstLayer.contentsGravity = srcLayer.contentsGravity;
	dstLayer.masksToBounds = srcLayer.masksToBounds;
}

static bool mvkDTRAttachCachedLayerToStableWindowHost(const void* surface, NSWindow* window, PLATFORM_VIEW_CLASS* view, CAMetalLayer* cachedLayer) {
	if ( !mvkDTRSurfaceStableWindowLayerEnabled() ) { return false; }
	if ( !window || !view || !cachedLayer ) { return false; }

	NSView* contentView = window.contentView;
	if ( !contentView ) {
		mvkDTRSurfaceLog("window stable layer skipped surface=%p window=%p view=%p layer=%p reason=no_content_view", surface, window, view, cachedLayer);
		return false;
	}

	if ( !contentView.wantsLayer ) { contentView.wantsLayer = YES; }
	CALayer* contentLayer = contentView.layer;
	if ( !contentLayer ) {
		mvkDTRSurfaceLog("window stable layer skipped surface=%p window=%p view=%p layer=%p reason=no_content_layer", surface, window, view, cachedLayer);
		return false;
	}

	NSMapTable* hostCache = mvkDTRSurfaceWindowHostLayerCache();
	CALayer* hostLayer = [hostCache objectForKey: window];
	if ( !hostLayer ) {
		hostLayer = [CALayer layer];
		hostLayer.name = @"MoltenVK stable window layer host";
		[hostCache setObject: hostLayer forKey: window];
		mvkDTRSurfaceLog("window stable host layer store surface=%p window=%p content_view=%p content_layer=%p host_layer=%p", surface, window, contentView, contentLayer, hostLayer);
	}

	CALayer* oldSuperlayer = cachedLayer.superlayer;
	CGRect hostBounds = contentView.bounds;
	CGRect viewFrame = [view convertRect: view.bounds toView: contentView];
	mvkDTRRunWithDisabledLayerActions(^{
		mvkDTRInstallDisabledLayerActions(contentLayer);
		mvkDTRInstallDisabledLayerActions(hostLayer);
		mvkDTRInstallDisabledLayerActions(cachedLayer);

		hostLayer.anchorPoint = CGPointZero;
		hostLayer.bounds = CGRectMake(0.0, 0.0, hostBounds.size.width, hostBounds.size.height);
		hostLayer.position = CGPointZero;
		hostLayer.hidden = NO;
		hostLayer.opacity = 1.0;
		hostLayer.masksToBounds = YES;
		hostLayer.zPosition = 1000000.0;
		hostLayer.contentsScale = cachedLayer.contentsScale;
		if (hostLayer.superlayer != contentLayer) { [contentLayer addSublayer: hostLayer]; }

		cachedLayer.anchorPoint = CGPointZero;
		cachedLayer.bounds = CGRectMake(0.0, 0.0, viewFrame.size.width, viewFrame.size.height);
		cachedLayer.position = viewFrame.origin;
		cachedLayer.zPosition = 0.0;
		if (cachedLayer.superlayer != hostLayer) { [hostLayer addSublayer: cachedLayer]; }
		cachedLayer.delegate = (id<CALayerDelegate>)view;
	});

	mvkDTRSurfaceLog("window stable layer attach surface=%p window=%p view=%p content_layer=%p host_layer=%p layer=%p old_superlayer=%p new_superlayer=%p frame=%.1f,%.1f %.1fx%.1f",
					 surface, window, view, contentLayer, hostLayer, cachedLayer, oldSuperlayer, cachedLayer.superlayer,
					 viewFrame.origin.x, viewFrame.origin.y, viewFrame.size.width, viewFrame.size.height);
	return true;
}

static CAMetalLayer* mvkDTRSurfaceCachedWindowLayer(const void* surface, CAMetalLayer* mtlLayer, const char* vkFuncName) {
	if ( !mvkDTRSurfaceCacheWindowLayerEnabled() || !mtlLayer ) { return mtlLayer; }

	__block CAMetalLayer* resolvedLayer = mtlLayer;
	mvkDispatchToMainAndWait(^{
		@autoreleasepool {
			id delegate = mtlLayer.delegate;
			if ( ![delegate isKindOfClass: [PLATFORM_VIEW_CLASS class]] ) {
				mvkDTRSurfaceLog("window layer cache skipped surface=%p func=%s layer=%p delegate=%p reason=non_view_delegate", surface, vkFuncName, mtlLayer, delegate);
				return;
			}

			PLATFORM_VIEW_CLASS* view = (PLATFORM_VIEW_CLASS*)delegate;
			NSWindow* window = view.window;
			if ( !window ) {
				mvkDTRSurfaceLog("window layer cache skipped surface=%p func=%s layer=%p view=%p reason=no_window", surface, vkFuncName, mtlLayer, view);
				return;
			}
			if ( !window.visible || CGRectIsEmpty(view.bounds) || CGRectIsEmpty(window.contentView.bounds) ) {
				mvkDTRSurfaceLog("window layer cache skipped surface=%p func=%s layer=%p view=%p window=%p reason=window_not_ready", surface, vkFuncName, mtlLayer, view, window);
				return;
			}

			NSMapTable* cache = mvkDTRSurfaceWindowLayerCache();
			CAMetalLayer* cachedLayer = [cache objectForKey: window];
			if ( !cachedLayer ) {
				mvkDTRInstallDisabledLayerActions(mtlLayer);
				[cache setObject: mtlLayer forKey: window];
				mvkDTRSurfaceLog("window layer cache store surface=%p func=%s window=%p view=%p layer=%p", surface, vkFuncName, window, view, mtlLayer);
				return;
			}

			if ( cachedLayer == mtlLayer ) {
				mvkDTRInstallDisabledLayerActions(cachedLayer);
				mvkDTRSurfaceLog("window layer cache same surface=%p func=%s window=%p view=%p layer=%p", surface, vkFuncName, window, view, mtlLayer);
				return;
			}

			mvkDTRRunWithDisabledLayerActions(^{
				mvkDTRInstallDisabledLayerActions(cachedLayer);
				mvkDTRCopyReusableLayerState(cachedLayer, mtlLayer);
				if ( !mvkDTRAttachCachedLayerToStableWindowHost(surface, window, view, cachedLayer) ) {
					if ( !view.wantsLayer ) { view.wantsLayer = YES; }
					if ( view.layer != cachedLayer ) { view.layer = cachedLayer; }
					cachedLayer.delegate = (id<CALayerDelegate>)view;
				}
			});
			resolvedLayer = cachedLayer;
			mvkDTRSurfaceLog("window layer cache hit surface=%p func=%s window=%p view=%p provided_layer=%p cached_layer=%p", surface, vkFuncName, window, view, mtlLayer, cachedLayer);
		}
	});

	return resolvedLayer;
}
#endif


#pragma mark MVKSurface

CAMetalLayer* MVKSurface::getCAMetalLayer() {
	std::lock_guard<std::mutex> lock(_layerLock);
	return _mtlCAMetalLayer;
}

VkExtent2D MVKSurface::getExtent() {
	return _mtlCAMetalLayer ? mvkVkExtent2DFromCGSize(_mtlCAMetalLayer.drawableSize) : kMVKUndefinedExtent;
}

VkExtent2D MVKSurface::getNaturalExtent() {
	return _mtlCAMetalLayer ? mvkVkExtent2DFromCGSize(_mtlCAMetalLayer.naturalDrawableSizeMVK) : kMVKUndefinedExtent;
}

void MVKSurface::setActiveSwapchain(MVKSwapchain* swapchain) {
	mvkDTRSurfaceLog("set active swapchain surface=%p old=%p new=%p layer=%p", this, _activeSwapchain, swapchain, _mtlCAMetalLayer);
	_activeSwapchain = swapchain;
	logNativeState("set active swapchain");
}

MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const VkMetalSurfaceCreateInfoEXT* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	initLayer((CAMetalLayer*)pCreateInfo->pLayer, "vkCreateMetalSurfaceEXT", false);
}

MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const VkHeadlessSurfaceCreateInfoEXT* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	initLayer(nil, "vkCreateHeadlessSurfaceEXT", true);
}

// pCreateInfo->pView can be either a CAMetalLayer or a view (NSView/UIView).
MVKSurface::MVKSurface(MVKInstance* mvkInstance,
					   const Vk_PLATFORM_SurfaceCreateInfoMVK* pCreateInfo,
					   const VkAllocationCallbacks* pAllocator) : _mvkInstance(mvkInstance) {
	MVKLogWarn("%s() is deprecated. Use vkCreateMetalSurfaceEXT() from the VK_EXT_metal_surface extension.", STR(vkCreate_PLATFORM_SurfaceMVK));

	// Get the platform object contained in pView
	// If it's a view (NSView/UIView), extract the layer, otherwise assume it's already a CAMetalLayer.
	id<NSObject> obj = (id<NSObject>)pCreateInfo->pView;
	if ([obj isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
		__block id<NSObject> layer;
		mvkDispatchToMainAndWait(^{ layer = ((PLATFORM_VIEW_CLASS*)obj).layer; });
		obj = layer;
	}

	// Confirm that we were provided with a CAMetalLayer
	initLayer([obj isKindOfClass: CAMetalLayer.class] ? (CAMetalLayer*)obj : nil, STR(vkCreate_PLATFORM_SurfaceMVK), false);
}

void MVKSurface::initLayer(CAMetalLayer* mtlLayer, const char* vkFuncName, bool isHeadless) {

#ifdef VK_USE_PLATFORM_MACOS_MVK
	mtlLayer = mvkDTRSurfaceCachedWindowLayer(this, mtlLayer, vkFuncName);
#endif
	_mtlCAMetalLayer = [mtlLayer retain];	// retained
	mvkDTRSurfaceLog("init layer surface=%p func=%s layer=%p delegate=%p headless=%u replace_env=%u cache_window_layer_env=%u stable_window_layer_env=%u disable_actions_env=%u", this, vkFuncName, _mtlCAMetalLayer, _mtlCAMetalLayer.delegate, isHeadless ? 1 : 0, mvkDTRSurfaceReplaceLayerEnabled() ? 1 : 0, mvkDTRSurfaceCacheWindowLayerEnabled() ? 1 : 0, mvkDTRSurfaceStableWindowLayerEnabled() ? 1 : 0, mvkDTRDisableLayerActionsEnabled() ? 1 : 0);
	logNativeState("init layer");
	if ( !_mtlCAMetalLayer && !isHeadless ) { setConfigurationResult(reportError(VK_ERROR_SURFACE_LOST_KHR, "%s(): On-screen rendering requires a layer of type CAMetalLayer.", vkFuncName)); }

	// Layer replacement tracking is fragile during CrossOver startup, so keep it opt-in.
	if (mvkDTRSurfaceReplaceLayerEnabled() && [_mtlCAMetalLayer.delegate isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
		_layerObserver = [MVKBlockObserver observerWithBlock: ^(NSString* path, id object, NSDictionary*, void*) {
			if ([path isEqualToString: @"layer"]) {
				mvkDTRSurfaceLog("observed view layer change surface=%p object=%p old_layer=%p active_swapchain=%p replace_env=%u", this, object, this->_mtlCAMetalLayer, this->_activeSwapchain, mvkDTRSurfaceReplaceLayerEnabled() ? 1 : 0);
				this->logNativeState("observed view layer change");
				if ([object isKindOfClass: [PLATFORM_VIEW_CLASS class]]) {
					__block CAMetalLayer* replacementLayer = nil;
					mvkDispatchToMainAndWait(^{
						CALayer* viewLayer = ((PLATFORM_VIEW_CLASS*)object).layer;
						if ([viewLayer isKindOfClass: CAMetalLayer.class]) { replacementLayer = [(CAMetalLayer*)viewLayer retain]; }
					});
					mvkDTRSurfaceLog("view layer replacement lookup surface=%p replacement=%p", this, replacementLayer);
					if (replacementLayer) {
						this->replaceLayer(replacementLayer);
						[replacementLayer release];
						return;
					}
				}
				this->releaseLayer();
			}
		} forObject: _mtlCAMetalLayer.delegate atKeyPath: @"layer"];
	}
}

void MVKSurface::replaceLayer(CAMetalLayer* mtlLayer) {
	{
		std::lock_guard<std::mutex> lock(_layerLock);
		if ( !mtlLayer || _mtlCAMetalLayer == mtlLayer ) { return; }

		mvkDTRSurfaceLog("replace layer surface=%p old_layer=%p new_layer=%p active_swapchain=%p", this, _mtlCAMetalLayer, mtlLayer, _activeSwapchain);
		[mtlLayer retain];
		[_mtlCAMetalLayer release];
		_mtlCAMetalLayer = mtlLayer;
		clearConfigurationResult();
		if (_activeSwapchain) { _activeSwapchain->setConfigurationResult(VK_ERROR_OUT_OF_DATE_KHR); }
		mvkDTRSurfaceLog("replace layer complete surface=%p layer=%p active_swapchain=%p", this, _mtlCAMetalLayer, _activeSwapchain);
	}
	logNativeState("replace layer complete");
	MVKLogInfo("Replaced CAMetalLayer on existing VkSurfaceKHR and marked active swapchain out of date.");
}

void MVKSurface::releaseLayer() {
	logNativeState("release layer");
	std::lock_guard<std::mutex> lock(_layerLock);
	mvkDTRSurfaceLog("release layer surface=%p layer=%p active_swapchain=%p", this, _mtlCAMetalLayer, _activeSwapchain);
	setConfigurationResult(VK_ERROR_SURFACE_LOST_KHR);
	[_mtlCAMetalLayer release];
	_mtlCAMetalLayer = nil;
	[_layerObserver release];
	_layerObserver = nil;
}

void MVKSurface::logNativeState(const char* stage) {
	if ( !mvkDTRSurfaceLogNativeEnabled() ) { return; }

	CAMetalLayer* layer = nil;
	MVKSwapchain* activeSwapchain = nullptr;
	{
		std::lock_guard<std::mutex> lock(_layerLock);
		layer = [_mtlCAMetalLayer retain];
		activeSwapchain = _activeSwapchain;
	}

	mvkDTRLogLayerNativeState(stage, this, layer, activeSwapchain);
	[layer release];
}

MVKSurface::~MVKSurface() {
	releaseLayer();
}
