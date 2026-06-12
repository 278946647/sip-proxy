from setuptools import find_packages, setup

setup(
    name="gfc-client-agent",
    version="0.3.0",
    packages=find_packages(exclude=["dist", "state", "docs"]),
    python_requires=">=3.10",
    install_requires=["requests>=2.32.0"],
)
