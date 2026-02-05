git checkout -b "release-1.0.0"
rm -rf .github/ISSUE_TEMPLATE
rm proto/command.proto
rm -rf sample-services/ai_assistant
rm -rf sample-services/mcp-servers
rm -rf sample-services/predictive-battery-maintenance
rm -rf sample-services/remote-lock
rm -rf sample-services/vhal-simulator
ls -la sample-services
ls -la .github
ls -la proto
git add .
git commit -m "cleanup for public release"
#Erstelle den leeren Branch (History-Reset)
git checkout --orphan staging-main
#Alle bereinigten Dateien stagen
git add -A
#finaler commit
git commit -m "Initial Open Source Release 1.0.0"
# Den orphan Branch zum Staging Repo pushen - Wir pushen den lokalen 'staging-main' auf den 'main' von 'staging'
git push staging staging-main:main --force
