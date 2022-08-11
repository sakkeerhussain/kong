return {
  name = "rewriter",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          { value = { type = "string", referenceable = true } },
          { extra = { type = "string", default = "extra" } },
        },
      },
    },
  },
}
