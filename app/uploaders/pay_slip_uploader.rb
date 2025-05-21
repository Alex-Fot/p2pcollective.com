class PaySlipUploader < Shrine
  plugin :validation_helpers
  plugin :determine_mime_type

  Attacher.validate do
    validate_max_size 5*1024*1024 # 5 MB
    validate_mime_type %w[image/jpeg image/png image/webp]
    validate_extension %w[jpg jpeg png webp]
  end
end