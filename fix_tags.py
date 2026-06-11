import os
import re

files = [
    "Tests/AppTests/LLM/LLMControllerPushSideEffectTests.swift",
    "Tests/AppTests/Memory/HermesMemoryServiceTests.swift",
    "Tests/AppTests/Memory/MemoryPruningServiceTests.swift",
    "Tests/AppTests/Memory/MemoGeneratorTests.swift",
    "Tests/AppTests/Achievements/AchievementsServiceTests.swift",
    "Tests/AppTests/Auth/HermesProvisioningLifecycleTests.swift",
    "Tests/AppTests/Auth/XOAuthTests.swift",
    "Tests/AppTests/Auth/SOULInitTests.swift",
    "Tests/AppTests/Auth/EmailVerificationTests.swift",
    "Tests/AppTests/Auth/AuthFlowTests.swift",
    "Tests/AppTests/Tenancy/TenantIsolationTests.swift",
    "Tests/AppTests/Health/HealthCorrelationServiceTests.swift",
    "Tests/AppTests/Admin/HermesProfileReconcilerTests.swift",
    "Tests/AppTests/Kanban/KanbanServiceTests.swift",
    "Tests/AppTests/Skills/UsageSummaryAggregationTests.swift",
    "Tests/AppTests/Skills/ProjectModelTests.swift",
    "Tests/AppTests/Skills/SkillRunnerTests.swift",
    "Tests/AppTests/Skills/ReminderSchedulerTests.swift",
    "Tests/AppTests/Skills/SkillRunnerLifecycleTests.swift",
    "Tests/AppTests/Skills/SkillRunCapGuardTests.swift",
    "Tests/AppTests/Services/APNSNotificationServiceTests.swift",
    "Tests/AppTests/Services/HermesProfileServiceTests.swift",
    "Tests/AppTests/Services/CronPushTests.swift",
    "Tests/AppTests/Billing/LapseArchiverTests.swift"
]

for filepath in files:
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Replace @Suite(...) with @Suite(..., .tags(.integration), .integrationDatabase)
    # But only if it doesn't already have it
    if ".tags(.integration)" not in content and "@Suite" in content:
        # Match @Suite or @Suite("...") or @Suite(.serialized)
        content = re.sub(r'@Suite\(([^)]+)\)', r'@Suite(\1, .tags(.integration), .integrationDatabase)', content)
        content = re.sub(r'^@Suite\s*\n', r'@Suite(.tags(.integration), .integrationDatabase)\n', content, flags=re.MULTILINE)
        
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"Updated {filepath}")
