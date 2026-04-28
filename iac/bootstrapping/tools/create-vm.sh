gcloud compute instances create nexus-release-tester \
    --project=nexus-boot-dae \
    --zone=europe-west3-c \
    --machine-type=e2-medium \
    --network=nexus-vpc \
    --subnet=nexus-subnet \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=20GB \
    --scopes=https://www.googleapis.com/auth/cloud-platform

