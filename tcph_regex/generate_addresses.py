from faker import Faker

fake = Faker("de_DE")

addresses = [fake.address() for _ in range(50)]

for addr in addresses:
    print(addr.replace("\n", ", "))