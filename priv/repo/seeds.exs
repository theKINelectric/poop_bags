# Seeding is unnecessary: the first real scan is the seed. Point the form at
# a project directory, or:
#
#     mix run -e '
#       {:ok, scan} = PoopBags.Catalog.create_scan(%{"project_path" => "/abs/path"})
#       PoopBags.ScanSupervisor.start_scan(scan.id)
#     '
