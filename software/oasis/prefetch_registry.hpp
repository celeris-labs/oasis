#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace oasis {

/**
 * Dependency-aware cross-pipeline hardware prefetch.
 *
 * One PrefetchRegistry exists per query. Every scan operator in the query registers one 
 * PrefetchNode. The registry tracks, for each node, how many of its dependency scans are still 
 * outstanding. When the last one clears the node's prefetch set is submitted, warming the hardware 
 * before the dependent pipeline executes.
 */
class PrefetchNode {
  public:
    // The action that submits this node's prefetch set onto the scheduler. Installed at 
    // registration time. Invoked exactly once, the first time the node's outstanding dependency 
    // count crosses zero (or immediately, for a root node with no dependencies).
    using SubmitFn = std::function<void()>;

    // A readiness signal fired right after `submit` runs, so a scan that reached its operator before
    // its prefetch existed (and parked itself BLOCKED) can be woken promptly.
    using WakeFn = std::function<void()>;

    explicit PrefetchNode(const void *key) : key_(key) {}

    const void *key() const { return key_; }

    void set_submit(SubmitFn fn) { submit_ = std::move(fn); }

    void add_dependent(PrefetchNode *dependent) {
        dependents_.push_back(dependent);
        dependent->outstanding_deps_.fetch_add(1, std::memory_order_relaxed);
    }

    size_t outstanding_deps() const { return outstanding_deps_.load(std::memory_order_acquire); }

    bool submitted() const { return submitted_.load(std::memory_order_acquire); }

    bool arm_wake(WakeFn fn) {
        std::lock_guard<std::mutex> g(wake_mutex_);
        if (submitted_.load(std::memory_order_acquire)) {
            return false;
        }
        wake_ = std::move(fn);
        return true;
    }

    void submit_once() {
        if (submitted_.exchange(true, std::memory_order_acq_rel)) {
            return; // Someone else already submitted this node.
        }
        if (submit_) {
            submit_();
        }
        WakeFn wake;
        {
            std::lock_guard<std::mutex> g(wake_mutex_);
            wake = std::move(wake_);
            wake_ = nullptr;
        }
        if (wake) {
            wake();
        }
    }

    void notify_dependents_last_splinter() {
        for (auto *dep : dependents_) {
            if (dep->outstanding_deps_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                dep->submit_once();
            }
        }
    }

  private:
    const void *key_;
    std::atomic<size_t> outstanding_deps_{0};
    std::atomic<bool> submitted_{false};
    std::vector<PrefetchNode *> dependents_;

    SubmitFn submit_;

    std::mutex wake_mutex_;
    WakeFn wake_;
};

/**
 * Per-query collection of PrefetchNodes. Nodes are registered (Phase 1) and then wired into a DAG
 * with a single pass (Phase 2). Roots submit immediately on wiring. Owned by the Scheduler's
 * per-Executor map and torn down at query end.
 */
class PrefetchRegistry {
  public:
    PrefetchNode &get_or_create(const void *key) {
        std::lock_guard<std::mutex> g(mutex_);
        auto it = nodes_.find(key);
        if (it != nodes_.end()) {
            return *it->second;
        }
        auto node = std::make_unique<PrefetchNode>(key);
        auto &ref = *node;
        nodes_.emplace(key, std::move(node));
        return ref;
    }

    PrefetchNode *find(const void *key) {
        std::lock_guard<std::mutex> g(mutex_);
        auto it = nodes_.find(key);
        return it == nodes_.end() ? nullptr : it->second.get();
    }

  private:
    std::mutex mutex_;
    std::unordered_map<const void *, std::unique_ptr<PrefetchNode>> nodes_;
};

} // namespace oasis
